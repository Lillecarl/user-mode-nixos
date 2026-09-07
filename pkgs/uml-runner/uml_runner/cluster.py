"""Bring a kubeadm cluster up on UML guests, and ask it questions.

A node knows nothing about the others -- see ``modules/k8s.nix`` -- so
everything needing the whole cluster in view lives here rather than in a
module: who joins whom, which /24 each node was given, the routes between
them, and whether anything is Ready.

This is a library and not a test.  ``tests/k8s.py`` is the three-node case,
and a caller outside this repository can build its own:

    from uml_runner import run_test
    from uml_runner.cluster import bring_up, kubectl

    async def test(vms):
        cp = await bring_up(vms)
        await kubectl(cp, "apply --filename /nix/store/...")

    run_test(test)

Everything a caller is likely to need is a coroutine over ``Machine``
objects, so nothing here assumes the guests came from this repository's
``flake.nix`` -- only that they run ``services.uml-k8s``.
"""

import asyncio
import json

from .machine import MachineError

# A control plane coming up under UML is minutes of work, and a failure
# here is nearly always slowness rather than breakage -- so these are
# deliberately far past the point where a real cluster would be up.
INIT_TIMEOUT = 30 * 60
JOIN_TIMEOUT = 20 * 60
READY_TIMEOUT = 15 * 60

POLL = 10

# The taint kubeadm puts on a control plane so that nothing schedules there.
CONTROL_PLANE_TAINT = "node-role.kubernetes.io/control-plane"


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

    A CI round trip on a cluster test is the better part of an hour, so a
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
    if not workers:
        return
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
    gets away with.  A real cluster would run an overlay here; guests on
    one Ethernet segment can just route.  A single node needs no routes
    at all and still needs the CNI configuration, or kubelet stays
    NotReady with "cni plugin not initialized".
    """
    # `kubeadm join` returns once the node has registered, which is not
    # the same instant kube-controller-manager's IPAM has given it a
    # /24: reading the node list straight afterwards is a race that a
    # fast join loses.
    cidrs = {}

    async def assigned():
        nodes = await get_json(cp, "get nodes")
        cidrs.clear()
        cidrs.update(
            {
                item["metadata"]["name"]: item["spec"].get("podCIDR")
                for item in nodes["items"]
            }
        )
        missing = sorted(name for name, cidr in cidrs.items() if not cidr)
        return not missing and len(cidrs) == len(vms), (
            f"without a podCIDR: {', '.join(missing) or 'none'}; "
            f"nodes: {', '.join(sorted(cidrs)) or 'none'}"
        )

    await until("every node to be given a podCIDR", assigned, JOIN_TIMEOUT, cp)
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


async def untaint(cp):
    """Let workloads run on the control plane.

    kubeadm taints it so that nothing schedules there, which is right for a
    cluster with workers and leaves a single-node cluster unable to run
    anything at all.  The trailing ``-`` is kubectl's syntax for removing a
    taint, and it is not an error when the taint is already gone.
    """
    await kubectl(cp, f"taint nodes --all {CONTROL_PLANE_TAINT}-")
    print("[k8s] control plane will schedule workloads", flush=True)


async def bring_up(vms, cp_name="cp", schedulable=None):
    """The whole sequence, from booted guests to a cluster that works.

    Returns the control plane machine.

    *schedulable* removes the control plane's taint.  The default decides by
    size: a single-node cluster has nowhere else to put a pod, and one with
    workers should keep the control plane for the control plane.
    """
    cp = vms[cp_name]
    workers = [vm for name, vm in vms.items() if name != cp_name]
    if schedulable is None:
        schedulable = not workers

    for vm in vms.values():
        await vm.wait_for_unit("containerd.service", timeout=300)
    await wait_for_images(vms)

    await init_control_plane(cp)
    await join(cp, workers)
    await wire_pod_network(cp, vms)

    await wait_for_ready_nodes(cp, len(vms))
    await wait_for_pods(cp, "--selector k8s-app=kube-proxy")
    await wait_for_pods(cp, "--selector k8s-app=kube-dns")

    if schedulable:
        await untaint(cp)

    return cp


__all__ = [
    "CONTROL_PLANE_TAINT",
    "INIT_TIMEOUT",
    "JOIN_TIMEOUT",
    "POLL",
    "READY_TIMEOUT",
    "bring_up",
    "diagnose",
    "get_json",
    "init_control_plane",
    "join",
    "kubectl",
    "untaint",
    "until",
    "wait_for_images",
    "wait_for_pods",
    "wait_for_ready_nodes",
    "wire_pod_network",
]
