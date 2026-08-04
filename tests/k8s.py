#!/usr/bin/env python3
"""A three-node kubeadm cluster, from `kubeadm init` to a working Service.

The nodes themselves know nothing about each other -- see modules/k8s.nix
-- so everything that needs the whole cluster in view happens here:

    init      kubeadm init on cp, and kubeadm join on the two workers
    network   read each node's podCIDR, write its CNI config, and route
              the other nodes' pod subnets over the segment
    verify    all three Ready, CoreDNS up, and a pod on one worker
              reaching a Service backed by a pod on the other

The point of the last step is that it cannot pass by accident: it only
works if the CNI bridge, the inter-node routes, kube-proxy's iptables
rules and cluster DNS all do their jobs.
"""

import asyncio
import json

from uml_runner import MachineError, run_test

# A control plane coming up under UML is minutes of work, and a failure
# here is nearly always slowness rather than breakage -- so these are
# deliberately far past the point where a real cluster would be up.
INIT_TIMEOUT = 30 * 60
JOIN_TIMEOUT = 20 * 60
READY_TIMEOUT = 15 * 60

POLL = 10


async def kubectl(cp, args, timeout=120):
    """Run kubectl on the control plane; returns its output."""
    return await cp.succeed(f"kubectl {args}", timeout=timeout)


async def get_json(cp, args, timeout=120):
    return json.loads(await kubectl(cp, f"{args} --output json", timeout=timeout))


async def until(what, check, timeout, machine):
    """Poll *check* until it says yes; returns what it last saw.

    *check* returns ``(done, evidence)``.  The evidence is reported on
    both paths, because "timed out waiting for nodes" on its own says
    nothing about which node was not ready.
    """
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while True:
        done, evidence = await check()
        if done:
            return evidence
        if loop.time() > deadline:
            raise MachineError(
                f"[{machine.name}] timed out waiting for {what}\n{evidence}\n"
                + await diagnose(machine)
            )
        await asyncio.sleep(POLL)


async def diagnose(vm):
    """Everything worth knowing about a node that would not come up.

    A CI round trip on this test is the better part of an hour, so a
    failure should answer the next question as well as the first one.
    kubelet says why it will not start; containerd says why a container
    would not; crictl says which ones exist; and the pod logs are where
    the control plane itself complains -- kubeadm's own output shows none
    of that, because from where it stands the apiserver simply never
    answered.
    """
    logs = (
        await vm.execute(
            "tail -n 40 -v /var/log/pods/*/*/*.log 2>&1 | tail -n 400"
        )
    )[1]
    return (
        f"--- [{vm.name}] addresses and routes ---\n"
        f"{(await vm.execute('ip -brief addr; ip route; ip -6 route'))[1]}\n"
        f"--- [{vm.name}] crictl ps -a ---\n{(await vm.execute('crictl ps -a'))[1]}\n"
        f"--- [{vm.name}] kubelet ---\n{await vm.journal('kubelet.service', lines=80)}\n"
        f"--- [{vm.name}] containerd ---\n{await vm.journal('containerd.service', lines=40)}\n"
        f"--- [{vm.name}] pod logs ---\n{logs}"
    )


async def wait_for_images(vms):
    """No node is any use to kubeadm until containerd has the images."""
    await asyncio.gather(
        *(
            vm.wait_for_unit("k8s-load-images.service", timeout=10 * 60)
            for vm in vms.values()
        )
    )


async def init_control_plane(cp):
    print("[k8s] cp: kubeadm init ...", flush=True)
    rc, out = await cp.execute(
        "kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --v=2",
        timeout=INIT_TIMEOUT,
    )
    if rc != 0:
        raise MachineError(
            f"[cp] kubeadm init failed (exit {rc}):\n{out}\n" + await diagnose(cp)
        )
    print("[k8s] cp: control plane is up", flush=True)


async def join(cp, workers):
    """Bring the workers in with a token minted for this run.

    The token and the CA hash come from kubeadm rather than being read
    out of /etc/kubernetes, but the join itself does not use the command
    line kubeadm prints -- see `uml-k8s-join`, which wraps them in a
    configuration carrying this cluster's timeouts.

    --config is not optional here, even though the cluster already
    exists and this command only mints a token.  Without it kubeadm
    defaults an InitConfiguration first, and defaulting always calls
    ChooseAPIServerBindAddress -- which asks the kernel which interface
    owns the default route and then wants a global address on it.  That
    tolerates finding no default route at all (it warns and uses
    0.0.0.0), but treats a default route whose interface has no global
    address as fatal: "unable to select an IP from default routes", on a
    control plane that is up and serving.

    Passing the config we ran init with avoids the question rather than
    answering it: ResolveBindAddress returns an advertise address that
    is already concrete without looking at an interface at all.
    """
    printed = await cp.succeed(
        "kubeadm token create --print-join-command"
        " --config /etc/kubernetes/kubeadm-config.yaml"
    )
    fields = printed.split()
    try:
        token = fields[fields.index("--token") + 1]
        # Pins the cluster CA, so a worker cannot be talked into
        # bootstrapping against something else answering on that address.
        digest = fields[fields.index("--discovery-token-ca-cert-hash") + 1]
    except (ValueError, IndexError):
        raise MachineError(
            f"[cp] could not read a join command out of:\n{printed}"
        ) from None
    endpoint = f"{cp.ip}:6443"

    async def one(worker):
        print(f"[k8s] {worker.name}: kubeadm join ...", flush=True)
        rc, out = await worker.execute(
            f"uml-k8s-join {endpoint} {token} {digest}",
            timeout=JOIN_TIMEOUT,
        )
        if rc != 0:
            raise MachineError(
                f"[{worker.name}] kubeadm join failed (exit {rc}):\n{out}\n"
                + await diagnose(worker)
            )
        print(f"[k8s] {worker.name}: joined", flush=True)

    await asyncio.gather(*(one(w) for w in workers))


async def wire_pod_network(cp, vms):
    """Give each node its CNI config, and a route to everyone else's pods.

    kube-controller-manager hands out a /24 per node, but nothing sets up
    a data path: this is the whole CNI, and it is about as small as one
    gets away with.  A real cluster would run an overlay here; three
    guests on one Ethernet segment can just route.
    """
    nodes = await get_json(cp, "get nodes")
    cidrs = {}
    for item in nodes["items"]:
        name = item["metadata"]["name"]
        cidr = item["spec"].get("podCIDR")
        if not cidr:
            raise MachineError(f"[cp] node {name} was never assigned a podCIDR")
        cidrs[name] = cidr
    print(f"[k8s] pod subnets: {cidrs}", flush=True)

    if set(cidrs) != set(vms):
        raise MachineError(
            f"[cp] the cluster has {sorted(cidrs)}, the test booted {sorted(vms)}"
        )

    async def one(vm):
        await vm.succeed(f"uml-k8s-cni {cidrs[vm.name]}")
        for peer in vms.values():
            if peer.name != vm.name:
                await vm.succeed(
                    f"ip route replace {cidrs[peer.name]} via {peer.ip} dev vec1"
                )

    await asyncio.gather(*(one(vm) for vm in vms.values()))


async def wait_for_ready_nodes(cp, expected):
    async def check():
        out = await kubectl(cp, "get nodes --no-headers")
        ready = [line for line in out.splitlines() if " Ready " in f" {line} "]
        return len(ready) == expected, out

    await until(f"{expected} Ready nodes", check, READY_TIMEOUT, cp)
    print(f"[k8s] all {expected} nodes Ready", flush=True)


async def wait_for_pods(cp, selector, namespace="kube-system"):
    """Wait until every pod matching *selector* is Ready."""

    async def check():
        pods = await get_json(cp, f"get pods --namespace {namespace} {selector}")
        items = pods["items"]
        ready = [
            pod
            for pod in items
            if any(
                c["type"] == "Ready" and c["status"] == "True"
                for c in pod["status"].get("conditions", [])
            )
        ]
        summary = "\n".join(
            f"    {pod['metadata']['name']}: {pod['status'].get('phase')}"
            for pod in items
        )
        return bool(items) and len(ready) == len(items), summary

    await until(f"pods {selector}", check, READY_TIMEOUT, cp)


MANIFEST = """
apiVersion: v1
kind: Pod
metadata:
  name: web
  labels: {{ app: web }}
spec:
  nodeName: {server}
  containers:
  - name: web
    image: {image}
    imagePullPolicy: Never
    command:
    - /bin/sh
    - -c
    - mkdir -p /www && echo {greeting} > /www/index.html && exec /bin/httpd -f -p 8080 -h /www
    ports:
    - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector: {{ app: web }}
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
spec:
  nodeName: {client}
  containers:
  - name: probe
    image: {image}
    imagePullPolicy: Never
    command: ["/bin/sleep", "3600"]
"""


async def check_cluster_networking(cp, vms, image):
    """A pod on one worker, reached through a Service from the other.

    Deliberately the long way round: name resolution through CoreDNS, a
    ClusterIP translated by kube-proxy, and a packet that has to leave
    one node's CNI bridge and arrive on another's.
    """
    greeting = "hello-from-the-other-node"
    workers = [name for name in vms if name != cp.name]
    manifest = MANIFEST.format(
        image=image, server=workers[0], client=workers[1], greeting=greeting
    )
    # nodeName rather than a nodeSelector: the point is to put the two
    # pods on different nodes, and asking the scheduler to do it leaves
    # the test dependent on how it feels about a two-worker cluster.
    await cp.succeed(
        f"cat <<'EOF' | kubectl apply --filename -\n{manifest}\nEOF",
        timeout=180,
    )

    for pod in ("web", "probe"):
        await wait_for_pods(
            cp, f"--field-selector metadata.name={pod}", namespace="default"
        )

    async def check():
        rc, out = await cp.execute(
            "kubectl exec probe -- wget -T 10 -qO-"
            " http://web.default.svc.cluster.local/",
            timeout=120,
        )
        return rc == 0 and greeting in out, out

    body = await until("the Service to answer", check, READY_TIMEOUT, cp)
    print(
        f"[k8s] probe on {workers[1]} reached web on {workers[0]}: {body.strip()}",
        flush=True,
    )


async def test(vms):
    cp = vms.cp
    workers = [vm for name, vm in vms.items() if name != "cp"]
    image = vms.settings["workloadImage"]
    print(
        f"[k8s] kubernetes {vms.settings['kubernetesVersion']}, "
        f"pods on {vms.settings['podSubnet']}",
        flush=True,
    )

    for vm in vms.values():
        await vm.wait_for_unit("containerd.service", timeout=300)
    await wait_for_images(vms)

    await init_control_plane(cp)
    await join(cp, workers)
    await wire_pod_network(cp, vms)

    await wait_for_ready_nodes(cp, len(vms))
    await wait_for_pods(cp, "--selector k8s-app=kube-proxy")
    await wait_for_pods(cp, "--selector k8s-app=kube-dns")

    await check_cluster_networking(cp, vms, image)

    print("[k8s] " + await kubectl(cp, "get nodes --output wide"), flush=True)


run_test(test)
