## Architecture

```
Host (Python)                           Guest (NixOS UML VM)
════════════                            ════════════════════
                                         
UmlMachine                              systemd services:
  │                                       ├─ uml-rpyc-server (Python/rpyc)
  ├─ rpyc client ──── ssl0=fd:N ────→    │   opens /dev/ttyS0 in raw mode
  │   (SocketStream)                     │   TtyStream → Channel → Service
  │   run/execute/list_units/            │   exposed: run, list_units,
  │   get_unit_info/journal              │     get_unit_info, get_unit_state,
  │                                      │     journal_messages
  ├─ vec0=passt (DHCP + SSH outside)     
  ├─ vec1=socketpair (inter-VM L2)       
  └─ hostfs shared-dir (uml_shared=)     
      uml-cmd-runner (fallback polling)
```

## Key files

| File | Role |
|------|------|
| `pkgs/uml-runner/uml_runner.py` | Host-side: `UmlMachine`, `UmlOrchestrator`. rpyc client, execute, systemd helpers |
| `pkgs/uml-runner/uml_rpyc_server.py` | Guest-side: rpyc server with `TtyStream`, `UmlRpycService` |
| `modules/default.nix` | NixOS module: kernel config, VDE, hostfs, services, root image |
| `pkgs/uml-runner/default.nix` | Runner pkg deps: asyncssh + rpyc |
| `pkgs/uml-kernel/default.nix` | Kernel build: ARCH=um, SSL=y, fd/vec drivers |
| `pkgs/uml-passt-bridge/src/main.rs` | Rust bridge: forks passt + UML, bridges Ethernet via socketpairs |
| `tests/vde_multi_vm.py` | Multi-VM test: socketpair vec1, ssl0, hostnames, ping |
| `flake.nix` | `mkUmlVM` helper, `vde-test` derivation |

## Dep chain

Runner deps: `python3.pkgs.asyncssh`, `python3.pkgs.rpyc`
Guest server deps (NixOS module): `python3.withPackages [rpyc systemd-python]`
Test env deps: `python3.withPackages [asyncssh rpyc]`

## execution priority

`execute()`: rpyc → shared-dir → SSH

## Status

| Feature | Status |
|---------|--------|
| Single VM boot via passt | ✓ |
| Multi-VM inter-VM ping (vec1 socketpair) | ✓ |
| Console-only test mode (hostfs polling) | ✓ |
| Hostfs shared-dir execute_shared | ✓ |
| SSL serial line (ssl0=fd) — raw byte stream | ✓ |
| rpyc TTY-backed server boots in guest | ✓ |
| rpyc client connects ("host connected") | ✓ |
| rpyc transparent RPC (run/list_units/etc) | ✗ — timing out |
| rpyc asyncio support | ✗ — rpyc 6.0.2 only sync; uses run_in_executor |
| Full test passing via rpyc | ✗ |

## rpyc issue

`TtyStream` wraps `/dev/ttyS0` in raw mode via `termios`/`tty.setraw()`. The `read` and `write` 
methods use `os.read`/`os.write`. The `poll` method uses `select.select()`.

Last error: `AsyncResultTimeout("result expired")` — the rpyc client's `execute_rpyc` call timed out.
Server logs: "host connected" → "ready" → "host disconnected" (server-side `_send` failed).

Potential issues:
1. `TtyStream.read()` — reads `count` bytes then returns. rpyc frames are 4B length + payload.
2. `TtyStream.write()` — os.write with partial writes handled by loop (just fixed).
3. TTY line discipline might still process some bytes even in raw mode.
4. Alternative: bypass TTY entirely — use a 2nd socketpair fd passed directly to the server
   via systemd `Sockets=` or env `RPYC_FD`.

rpyc 6.0.2 on nixpkgs has no asyncio support — only blocking `serve()`/`serve_all()`/`sync_request()`.
The runner uses `loop.run_in_executor(None, ...)` to wrap blocking rpyc calls in threads.

Recent fix: `TtyStream.write` now uses `os.write()` in a loop (was `os.writev`). `TtyStream.poll` now
catches TypeError from `select.select()` on bad timeout values.

The last build timed out with `AsyncResultTimeout("result expired")` — the `execute_rpyc` call timed
out waiting for the server's response. Server logs showed "host connected" → "ready" → "host
disconnected", suggesting the write fix may not have resolved the underlying issue, or a new build
wasn't attempted after the write fix.

Binary not built after the latest fix and not pushed.
