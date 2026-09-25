"""A guest as a rootless OCI container, run by crun.

No kernel boot: the guest's systemd runs as PID 1 in a user, PID, mount,
cgroup and network namespace of its own, as the user who started the run.
``docs/design/running-anywhere.md`` (Area 8) has the measurements this is
built on.

Three pieces, each for a fact measured before it was written:

* :func:`oci_config`, the bundle's ``config.json``. Pure, so it is tested
  without a container.
* :func:`probe`, what the host must have, tried rather than read.
* :func:`main`, the launcher. crun gives systemd a console only with
  ``terminal: true``, and then hands the pty master over a socket instead
  of relaying it -- to a pipe it says "tcgetattr: Inappropriate ioctl for
  device" and exits. The launcher takes the master and copies it to its own
  stdout, which is what :class:`~uml_runner.machine.Machine` reads.
"""

from __future__ import annotations

import os
import pwd
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

AGENT_DIR = "/run/host/agent"
"""Where the guest sees the host's agent directory."""

AGENT_SOCKET = f"{AGENT_DIR}/sock"

SUBORDINATE_IDS = 65536
"""How many ids beyond root the guest gets. 65534 is ``nobody``, so fewer
leaves a service that runs as it unable to start."""

CAPABILITIES = [
    "CAP_" + name
    for name in (
        "CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER FSETID KILL SETGID SETUID "
        "SETPCAP LINUX_IMMUTABLE NET_BIND_SERVICE NET_BROADCAST NET_ADMIN "
        "NET_RAW IPC_LOCK IPC_OWNER SYS_MODULE SYS_RAWIO SYS_CHROOT "
        "SYS_PTRACE SYS_PACCT SYS_ADMIN SYS_BOOT SYS_NICE SYS_RESOURCE "
        "SYS_TIME SYS_TTY_CONFIG MKNOD LEASE AUDIT_WRITE AUDIT_CONTROL "
        "SETFCAP MAC_OVERRIDE MAC_ADMIN SYSLOG WAKE_ALARM BLOCK_SUSPEND "
        "AUDIT_READ PERFMON BPF CHECKPOINT_RESTORE"
    ).split()
]
"""Every capability, in the guest's own user namespace only. An empty set
is what crun gives when the field is left out, and systemd then fails
every ``User=`` service at the GROUP step (measured)."""


@dataclass(frozen=True)
class Range:
    """A run of subordinate ids from ``/etc/subuid`` or ``/etc/subgid``."""

    start: int
    count: int


def subordinate(path: Path, user: str, uid: int) -> Range | None:
    """The first range *path* gives *user*, by name or by number."""
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        fields = line.strip().split(":")
        if len(fields) == 3 and fields[0] in (user, str(uid)):
            return Range(int(fields[1]), int(fields[2]))
    return None


def _mapping(host: int, extra: Range) -> list[dict]:
    return [
        {"containerID": 0, "hostID": host, "size": 1},
        {"containerID": 1, "hostID": extra.start, "size": SUBORDINATE_IDS},
    ]


def _bind(source: str, destination: str, *options: str) -> dict:
    return {
        "destination": destination,
        "type": "bind",
        "source": source,
        "options": ["rbind", *options],
    }


def _fs(kind: str, destination: str, *options: str) -> dict:
    return {
        "destination": destination,
        "type": kind,
        "source": kind,
        "options": list(options),
    }


def oci_config(
    *,
    hostname: str,
    init: str,
    setpriv: str,
    rootfs: Path,
    store: str,
    agent_dir: Path,
    artifacts: Path | None,
    uid: int,
    gid: int,
    subuid: Range,
    subgid: Range,
) -> dict:
    """The ``config.json`` for one guest.

    The mounts are in the order crun applies them, and the order matters:
    the agent's bind lands on the ``/run`` tmpfs, so it comes after it.

    ``/nix/store`` is the host's, read-only, as nixpkgs' nspawn containers
    have it. A guest that writes to its store needs the overlay the other
    backends build; unprivileged overlayfs in a user namespace is not
    measured here yet.
    """
    mounts = [
        _fs("proc", "/proc", "nosuid", "noexec", "nodev"),
        _fs("tmpfs", "/dev", "nosuid", "strictatime", "mode=755", "size=65536k"),
        # gid 3 is NixOS' `tty`. NixOS' own devpts mount asks for it, and
        # says "Invalid gid '3'" where the guest has only one id.
        _fs(
            "devpts",
            "/dev/pts",
            "nosuid",
            "noexec",
            "newinstance",
            "ptmxmode=0666",
            "mode=0620",
            "gid=3",
        ),
        _fs("tmpfs", "/dev/shm", "nosuid", "noexec", "nodev", "mode=1777"),
        _fs("mqueue", "/dev/mqueue", "nosuid", "noexec", "nodev"),
        _fs("sysfs", "/sys", "nosuid", "noexec", "nodev"),
        _fs("cgroup", "/sys/fs/cgroup", "nosuid", "noexec", "nodev", "rw"),
        _fs("tmpfs", "/run", "nosuid", "nodev", "mode=755"),
        _fs("tmpfs", "/tmp", "nosuid", "nodev", "mode=1777"),
        _bind(f"{store}/store", "/nix/store", "ro"),
        _bind(str(agent_dir), AGENT_DIR, "rw"),
    ]
    if artifacts is not None:
        mounts.append(_bind(str(artifacts), "/artifacts", "rw"))

    return {
        "ociVersion": "1.0.2",
        "hostname": hostname,
        "root": {"path": str(rootfs), "readonly": False},
        "process": {
            "terminal": True,
            "user": {"uid": 0, "gid": 0},
            # The init dies with crun, and the PID namespace with it. crun
            # does not arrange that: SIGKILLed, it left the guest running.
            "args": [setpriv, "--pdeathsig", "KILL", "--", init],
            "env": [
                "PATH=/run/current-system/sw/bin",
                "container=crun",
                "TERM=dumb",
            ],
            "cwd": "/",
            "capabilities": {
                "bounding": CAPABILITIES,
                "effective": CAPABILITIES,
                "permitted": CAPABILITIES,
            },
            "noNewPrivileges": False,
        },
        "mounts": mounts,
        "linux": {
            "namespaces": [
                {"type": kind}
                for kind in ("pid", "ipc", "uts", "mount", "cgroup", "network", "user")
            ],
            "uidMappings": _mapping(uid, subuid),
            "gidMappings": _mapping(gid, subgid),
            "maskedPaths": [],
            "readonlyPaths": [],
        },
    }


# ── what the host must have ─────────────────────────────────────────


@dataclass(frozen=True)
class Missing:
    """One thing the host lacks, and what gives it."""

    what: str
    why: str
    remedy: str

    def __str__(self) -> str:
        return f"{self.what}: {self.why}\n    fix: {self.remedy}"


def _unshare_user() -> None:
    os.unshare(os.CLONE_NEWUSER)


def _own_cgroup() -> Path | None:
    try:
        line = Path("/proc/self/cgroup").read_text().splitlines()[0]
    except (OSError, IndexError):
        return None
    return Path("/sys/fs/cgroup" + line.split(":", 2)[2])


def probe(user: str | None = None, uid: int | None = None) -> list[Missing]:
    """What this host lacks for a container guest; empty when nothing.

    Each check does the thing once. Reading configuration is not enough:
    an AppArmor profile or a seccomp filter shows only as a failed attempt.
    """
    uid = os.getuid() if uid is None else uid
    user = user or pwd.getpwuid(uid).pw_name
    missing: list[Missing] = []

    try:
        subprocess.run([sys.executable, "-c", ""], preexec_fn=_unshare_user, check=True)
        userns = True
    except (OSError, subprocess.SubprocessError):
        userns = False
    if not userns:
        missing.append(
            Missing(
                "a user namespace",
                "unshare(CLONE_NEWUSER) failed",
                "allow unprivileged user namespaces: user.max_user_namespaces > 0, "
                "and on Ubuntu kernel.apparmor_restrict_unprivileged_userns=0",
            )
        )

    ranges = {}
    for name, path in (("subuid", Path("/etc/subuid")), ("subgid", Path("/etc/subgid"))):
        found = subordinate(path, user, uid)
        if found is None or found.count < SUBORDINATE_IDS:
            missing.append(
                Missing(
                    f"{SUBORDINATE_IDS} subordinate ids in {path}",
                    f"{user} has {found.count if found else 'none'}",
                    f"NixOS: users.users.{user}.autoSubUidGidRange = true; "
                    f"elsewhere: usermod --add-{name}s 100000-165535 {user}",
                )
            )
        else:
            ranges[name] = found
    if userns and len(ranges) == 2:
        for helper, host, extra in (
            ("newuidmap", uid, ranges["subuid"]),
            ("newgidmap", os.getgid(), ranges["subgid"]),
        ):
            why = _try_map(helper, host, extra)
            if why:
                missing.append(
                    Missing(
                        f"a working {helper}",
                        why,
                        "install shadow's uidmap tools, setuid or with "
                        "cap_setuid/cap_setgid; NixOS has them in /run/wrappers/bin",
                    )
                )

    cgroup = _own_cgroup()
    if cgroup is None or not os.access(cgroup, os.W_OK):
        missing.append(
            Missing(
                "a cgroup to write in",
                f"{cgroup or 'no cgroup v2'} is not writable",
                "run under systemd-run --user --scope -p Delegate=yes",
            )
        )
    return missing


def _try_map(helper: str, host: int, extra: Range) -> str | None:
    """Map one subordinate id into a fresh user namespace with *helper*.

    Tried, not read: NixOS' wrappers carry file capabilities and no setuid
    bit, so a mode check refuses a helper that works (measured).
    """
    path = _which(helper)
    if path is None:
        return "not on PATH"
    # A child in a user namespace of its own, alive until its stdin closes.
    child = subprocess.Popen(
        [sys.executable, "-c", "import sys; sys.stdin.read()"],
        stdin=subprocess.PIPE,
        preexec_fn=_unshare_user,
    )
    try:
        done = subprocess.run(
            [path, str(child.pid), "0", str(host), "1", "1", str(extra.start), "1"],
            capture_output=True,
            text=True,
        )
    finally:
        assert child.stdin is not None
        child.stdin.close()
        child.wait()
    if done.returncode != 0:
        return f"{path} failed: {(done.stderr or done.stdout).strip()}"
    return None


def _which(name: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(":"):
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


# ── the launcher ─────────────────────────────────────────────────────


def _die_with_parent() -> None:
    # Imported here: backend imports this module.
    from .backend import die_with_parent

    die_with_parent()


def _relay(master: int, crun: subprocess.Popen) -> None:
    """Copy the guest's console to stdout until the guest is gone."""
    out = sys.stdout.buffer
    selector = selectors.DefaultSelector()
    selector.register(master, selectors.EVENT_READ)
    while True:
        if not selector.select(timeout=0.5):
            if crun.poll() is not None:
                return
            continue
        try:
            data = os.read(master, 65536)
        except OSError:
            # EIO: no slave end is open at this moment. That is not the
            # end of the guest: systemd hangs the console up as it starts
            # and opens it again, and a relay that stopped here lost every
            # line after "starting systemd..." (measured). crun's exit is
            # the end.
            if crun.poll() is not None:
                return
            time.sleep(0.05)
            continue
        if not data:
            return
        out.write(data)
        out.flush()


def main(argv: list[str] | None = None) -> int:
    """``python -m uml_runner.crun_launch CRUN STATE BUNDLE NAME``."""
    crun_bin, state, bundle, name = argv or sys.argv[1:]
    crun = [crun_bin, "--root", state, "--cgroup-manager=disabled"]

    # A short directory: a sockaddr_un holds 108 bytes, and a bundle under
    # a long TMPDIR does not fit.
    sockets = Path(tempfile.mkdtemp(prefix="uml-crun-", dir="/tmp"))
    console = sockets / "console"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(console))
    listener.listen(1)

    proc = subprocess.Popen(
        [*crun, "run", "--bundle", bundle, "--console-socket", str(console), name],
        stdin=subprocess.DEVNULL,
        # Its own group, so a signal to the runner's group reaches this
        # process and not crun: crun would pass SIGTERM to systemd, which
        # reads it as "re-execute".
        start_new_session=True,
        preexec_fn=_die_with_parent,
    )

    def stop(signum: int, _frame) -> None:
        subprocess.run([*crun, "kill", name, "KILL"], capture_output=True)

    signal.signal(signal.SIGTERM, stop)

    listener.settimeout(0.5)
    master: int | None = None
    try:
        while master is None and proc.poll() is None:
            try:
                conn, _ = listener.accept()
            except TimeoutError:
                continue
            _, fds, _, _ = socket.recv_fds(conn, 1024, 1)
            conn.close()
            master = fds[0]
        if master is not None:
            _relay(master, proc)
        return proc.wait()
    finally:
        listener.close()
        console.unlink(missing_ok=True)
        sockets.rmdir()
        if proc.poll() is None:
            stop(signal.SIGTERM, None)
            proc.wait()
        subprocess.run([*crun, "delete", "--force", name], capture_output=True)

