"""What a guest is made of, for each kind of machine.

:class:`Machine` owns a guest's lifetime and its console, and everything it
does above this file is the same whichever backend it has.  A backend's
whole job is to answer one question: what do I exec, with which fds, and
what else has to be running alongside it.

The host-side plumbing is shared, not reimplemented.  Both backends take:

    the agent socketpair    a fd carrying arpyc, raw
    the segment fd          a fd from :mod:`uml_runner.net`, raw frames
    passt                   started from :mod:`uml_runner.forward`'s specs

UML takes the segment fd as ``vec1:transport=fd``; QEMU takes the same fd
as ``dgram,local.type=fd``.  Both are plain ``send``/``recv`` on the fd
with no framing, which is why one segment can hold guests of either kind.

The difference is passt.  UML's vector transport has no length prefix and
passt has one, so a UML guest runs behind ``uml-passt-bridge``, which
forks passt and translates.  QEMU speaks passt's protocol itself, so the
bridge is not in the picture and the runner starts passt directly.
"""

from __future__ import annotations

import os
import socket
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import forward


class BackendError(Exception):
    """A guest could not be assembled: a helper that would not start."""

_VECTOR_DEPTH = 64
"""Frames per ``sendmmsg``/``recvmmsg``, and NAPI's poll weight, for UML.

Also how many receive buffers the driver keeps allocated per interface,
each one MTU-sized -- so at a jumbo MTU this is megabytes of the guest's
RAM.  There is no point going deep: AF_UNIX lets about ten frames sit in
a socketpair, so nothing beyond that is ever in flight."""


@dataclass
class Launch:
    """One guest's process, and whatever has to outlive its start."""

    argv: list[str]
    pass_fds: tuple[int, ...]
    env: dict[str, str] = field(default_factory=dict)
    helpers: list[subprocess.Popen] = field(default_factory=list)
    """Side processes the guest needs -- virtiofsd, passt -- for the
    backends that do not hide them behind something else.  Killed when the
    guest is torn down, in this order."""


class Uml:
    """A guest as an ordinary Linux process.

    Asks nothing of the host: no ``/dev/kvm``, no root, no tap device. One
    processor, and a trap into the host kernel for every guest syscall.
    """

    name = "uml"

    def launch(self, machine, rundir: Path, agent_fd: int, lan_fd: int | None) -> Launch:
        spec, tools = machine.spec, machine.tools
        argv = [
            str(tools.bridge),
            "--vec",
            self._vec(0, 3, spec.mtu),
            *forward.to_args(machine.forward),
            str(tools.kernel),
            f"ubd0={rundir}/cow,{spec.image}",
            "root=/dev/ubda",
            "rw",
            "init=/init",
            f"mem={spec.memory}",
            f"ssl0=fd:{agent_fd}",
            # Catch the guest's syscalls with a seccomp filter instead of
            # ptrace: fewer context switches per trap and per page fault,
            # which measures a few percent on throughput and about five
            # seconds off a boot.  "auto" falls back to ptrace where the
            # host will not let us install a filter, rather than
            # refusing to boot the way "on" does.
            "seccomp=auto",
        ]
        if lan_fd is not None:
            argv.append(self._vec(1, lan_fd, spec.mtu))

        pass_fds = tuple(fd for fd in (agent_fd, lan_fd) if fd is not None)
        # The bridge finds passt on PATH.
        env = dict(os.environ, PATH=f"{tools.passt.parent}:{os.environ['PATH']}")
        return Launch(argv=argv, pass_fds=pass_fds, env=env)

    @staticmethod
    def _vec(unit: int, fd: int, mtu: int) -> str:
        """A ``vecN=`` device on *fd*.

        ``mtu`` is only settable here: the driver leaves ``max_mtu`` at
        ``ether_setup``'s 1500, so ``ip link set mtu`` cannot raise it
        afterwards.

        No ``gro=1``: all it does is fix the receive buffers at 64K so
        that a transport with virtio-net headers can deliver a segment
        larger than the MTU.  ``fd`` has no such headers -- nothing ever
        arrives bigger than a frame -- so it would only mean allocating
        64K per frame and throwing most of it away.
        """
        return f"vec{unit}:transport=fd,fd={fd},depth={_VECTOR_DEPTH},mtu={mtu}"


class Qemu:
    """A guest as a virtual machine, with KVM.

    Needs ``/dev/kvm``: ``accel=kvm`` and never ``accel=kvm:tcg``, because
    the fallback is silent and ten times slower, so a builder that lost KVM
    would only look like a slow day.
    """

    name = "qemu"

    def launch(self, machine, rundir: Path, agent_fd: int, lan_fd: int | None) -> Launch:
        helpers: list[subprocess.Popen] = []
        try:
            return self._launch(machine, rundir, agent_fd, lan_fd, helpers)
        except BaseException:
            # Nothing owns these until a Launch carries them back, so a
            # failure between the first helper and the last would leave a
            # daemon behind -- and a test that fails while booting is
            # exactly when that happens.
            for helper in helpers:
                if helper.poll() is None:
                    helper.kill()
                    helper.wait()
            raise

    def _launch(
        self,
        machine,
        rundir: Path,
        agent_fd: int,
        lan_fd: int | None,
        helpers: list[subprocess.Popen],
    ) -> Launch:
        spec, tools = machine.spec, machine.tools

        vfs_sock = rundir / "virtiofsd.sock"
        helpers.append(self._virtiofsd(tools, vfs_sock, spec.store))

        scratch = self._scratch_disk(tools, rundir, spec.image)

        passt_fd, passt_proc = self._passt(tools, machine.forward)
        helpers.append(passt_proc)

        boot = spec.boot
        argv = [
            str(tools.qemu),
            "-machine", "q35,accel=kvm,memory-backend=guest-memory",
            "-cpu", "host",
            "-smp", str(spec.cpus),
            "-m", spec.memory,
            "-nodefaults", "-no-reboot", "-display", "none",
            # vhost-user-fs reads the guest's RAM directly, so the RAM has
            # to be a shared memfd rather than anonymous.  Without this,
            # virtiofsd connects and every read returns nothing.
            "-object",
            f"memory-backend-memfd,id=guest-memory,size={spec.memory},share=on",
            "-kernel", boot["kernel"],
            "-initrd", boot["initrd"],
            "-append", f"{boot['cmdline']} init={boot['toplevel']}/init",
            # The root, as /dev/vda. The only disk, so the guest names it
            # directly rather than waiting for udev to find a label.
            "-drive", f"file={scratch},if=virtio,format=qcow2",
            # The console, read by Machine._pump_console.
            "-serial", "stdio",
            "-chardev", f"socket,id=virtiofs,path={vfs_sock}",
            "-device", "vhost-user-fs-pci,chardev=virtiofs,tag=nix",
            # The control channel: the same socketpair UML gets on ssl0.
            "-chardev", f"socket,id=agent,fd={agent_fd}",
            "-device", "virtio-serial",
            "-device", "virtconsole,chardev=agent",
            "-netdev", f"stream,id=vec0,addr.type=fd,addr.str={passt_fd}",
            "-device", f"virtio-net-pci,netdev=vec0,mac={spec.mac(0)}",
        ]
        if lan_fd is not None:
            argv += [
                "-netdev", f"dgram,id=vec1,local.type=fd,local.str={lan_fd}",
                "-device",
                f"virtio-net-pci,netdev=vec1,mac={spec.mac(1)},host_mtu={spec.mtu}",
            ]

        pass_fds = tuple(
            fd for fd in (agent_fd, passt_fd, lan_fd) if fd is not None
        )
        return Launch(argv=argv, pass_fds=pass_fds, helpers=helpers)

    @staticmethod
    def _scratch_disk(tools, rundir: Path, image: Path | None) -> Path:
        """A writable layer over the read-only root image.

        The same shape as UML's ``ubd0=<cow>,<image>``: the image stays in
        the store and everything the guest writes lands here, to be thrown
        away with the run directory.
        """
        if image is None:
            raise BackendError("this guest has no root image")
        scratch = rundir / "root.qcow2"
        done = subprocess.run(
            [
                str(tools.qemu_img), "create",
                "-q",
                "-f", "qcow2",
                # Named, because qemu-img refuses to guess a backing
                # format and a guess would be silently wrong.
                "-F", "raw",
                "-b", str(image),
                str(scratch),
            ],
            capture_output=True,
            text=True,
        )
        if done.returncode != 0:
            raise BackendError(
                f"could not make a scratch disk over {image}: "
                f"{(done.stderr or done.stdout).strip()}"
            )
        return scratch

    @staticmethod
    def _virtiofsd(tools, socket_path: Path, store: str) -> subprocess.Popen:
        """Serve the host's store, and wait until it will answer.

        ``--no-announce-submounts`` is load-bearing, and the failure it
        avoids names nothing useful.  NixOS binds ``/nix/store`` onto
        itself, so ``store`` is a submount of the shared directory.
        Announced, the guest makes it an automount dentry, and overlayfs
        refuses one as a lower layer -- ``ovl_dentry_weird`` rejects
        ``DCACHE_NEED_AUTOMOUNT`` and every lookup under ``/nix/store``
        fails with ``EREMOTE``.  What that reads as, from the initrd, is
        ``Failed to resolve path ... : Object is remote``, on a store the
        guest can list one directory above.

        The cost of turning it off: the guest sees one inode number space
        across what were two filesystems on the host.  Two host
        filesystems sharing an inode number would alias.  That cannot
        happen while ``/nix/store`` is a bind of ``/nix``.
        """
        proc = subprocess.Popen(
            [
                str(tools.virtiofsd),
                f"--socket-path={socket_path}",
                f"--shared-dir={store}",
                # Nothing left to drop: this is already unprivileged, and
                # namespace sandboxing needs privileges a build does not
                # have.
                "--sandbox", "none",
                "--cache", "auto",
                "--no-announce-submounts",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 10
        while not socket_path.exists():
            if proc.poll() is not None:
                raise BackendError(
                    f"virtiofsd exited ({proc.returncode}) before serving {store}"
                )
            if time.monotonic() > deadline:
                proc.kill()
                raise BackendError(f"virtiofsd never made {socket_path}")
            time.sleep(0.02)
        return proc

    @staticmethod
    def _passt(tools, rules) -> tuple[int, subprocess.Popen]:
        """Start passt on one end of a socketpair; return QEMU's end.

        No bridge: passt frames with a 4-byte big-endian length prefix,
        which is QEMU's own socket protocol, so the two talk directly.
        The specifiers are the ones forward.py builds for UML, unchanged.
        """
        qemu_end, passt_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        proc = subprocess.Popen(
            [
                str(tools.passt),
                "--foreground",
                "--quiet",
                "--fd", str(passt_end.fileno()),
                *forward.to_args(rules),
            ],
            pass_fds=(passt_end.fileno(),),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
        )
        passt_end.close()
        # Kept open until the guest has spawned; Machine closes it after.
        return qemu_end.detach(), proc


BACKENDS = {backend.name: backend() for backend in (Uml, Qemu)}


def get(name: str):
    """The backend called *name*, as the spec's ``backend`` field names it."""
    try:
        return BACKENDS[name]
    except KeyError:
        raise ValueError(
            f"no backend {name!r}; have {', '.join(sorted(BACKENDS))}"
        ) from None
