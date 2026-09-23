1 # Running anywhere: a design, not a plan
1
1 **Status: draft. Nothing here is decided.** Carl and Claude write this
1 together. It exists because the next four changes cement the shape of the
1 runner, and some of them replace what is there now.
1
2 **Every line carries its iteration number.** A line that has not changed
2 since the first draft reads `1`. A line that a round of feedback changed
2 or added reads the number of that round. So a reader looks at the highest
2 numbers and sees what is new. The prefixes go away when the design
2 settles.
2
1 ## The goal
1
1 > Everything that is not a push to a registry or a cache must run on any
1 > machine, through user-mode-nixos.
1
1 CI then stops being the place where the answer lives. It becomes one more
1 caller of a thing a developer runs the same way.
1
1 Four things must be easy for that to be true:
1
1 1. Tell a run what to do from outside. Environment variables first, so a
1    run does one case of a suite instead of all of it.
1 2. Get the output back. A known directory on the host, easy to grep.
1 3. Maybe: filter what reaches the terminal. The same stream also goes to
1    the output directory.
1 4. Later: an MCP server. An agent starts a run, sets a breakpoint, gets a
1    notification, and runs Python inside the guest.
1
2 Two more, from the first round of feedback:
2
2 5. Copy and stream things out of a guest, easily.
2 6. Turn the guests' internet off in an unsandboxed run, so that a test
2    written for the sandbox can be iterated on outside it.
1
1 ## What exists today
1
1 Facts, with the file that holds them.
1
1 - A test is a derivation. `mkTest` builds `attempt`, which never fails, and
1   a second derivation reads its `status` file (`lib.nix:353`).
1 - The test script is the program. The derivation runs
1   `python3 ${script} --spec ${spec}`, and the script ends with
1   `run_test(test)` at module level (`tests/artifacts.py`).
1 - `run_test` boots the guests, runs the coroutine, and tears the guests
1   down in a `finally` (`harness.py:113`). Every run ends the same way.
1 - There are two entry points, not one. `run-uml` boots one guest from
1   command-line arguments (`cli.py`). `run_test` boots a spec.
1 - `/artifacts` is a host directory, one per guest, on both backends
1   (`harness.py:142`, `modules/image.nix:60`, `modules/qemu.nix:140`).
1 - A sandboxed run writes `log`, `report.json`, `status` and `artifacts/`
1   into `$out`. A run by hand writes the artifacts to a new temporary
1   directory and keeps nothing else (`harness.py:135`, `lib.nix:330`).
1 - Everything the run prints goes to one stream, with a prefix: `[test]`,
1   `[uml]`, `[time]`, and `[<machine>]` for a guest's console
1   (`machine.py:398`).
1 - The agent takes a method call over a serial line, and the dispatch is
1   generic: `exposed_<name>` (`arpyc.py:29`).
2 - **The agent serves one command at a time, and each one runs to
2   completion** (`agent.py:10`, `subprocess.run`). So nothing streams out
2   of a guest today, and a long command blocks every other question.
2 - A guest reaches the internet through passt, which the runner always
2   starts (`backend.py`). There is no switch that turns it off.
1
2 ## Decided
2
2 From Carl's first round of feedback. These close open questions 1, 4 and
2 5 of the first draft.
2
2 - **user-mode-nixos is a CLI application.** It reads a guest spec, sets
2   the guests up, and executes user Python. The runner owns the process.
2   The script stops being the program.
2 - **The Python runs on the host**, in both cases. It reaches a guest over
2   the RPC. Sandboxed, the same Python runs inside the build sandbox, and
2   still not inside a guest.
2 - **The CLI takes one or more scripts.** More than one is what allows a
2   standard library: boot a machine, bring up a Kubernetes cluster, and so
2   on, written once and reused by every consumer.
2 - **Output: `$out` when sandboxed, and a path the caller names when not.**
2   CLI flag or environment variable, either is fine.
2 - **A sandboxed run is worth keeping.** Nix distributes it to a build
2   machine, so it does not have to run locally. Its one cost is that the
2   guests have no internet.
1
2 ## Area 0 — the CLI, and what a script is
2
2 This is the change that cements the rest, so it comes first.
2
2 Today the concerns are mixed. `harness.py` parses the command line, boots
2 the guests, runs the test, tears the guests down and writes the report.
2 `run_test(test)` is both the library call and the entry point, so a test
2 module cannot be imported without starting a run. `cli.py` is a second
2 door into the same work with different arguments.
2
2 The shape to move to:
2
2 ```console
2 $ uml run --spec <spec.json> --out <dir> recipes/kubernetes.py mytest.py
2 ```
2
2 The CLI owns the spec, the guests, the output directory, the steer and
2 the teardown. A script contributes work and nothing else.
2
2 What a script exports is the first open question below. The smallest form
2 that supports a standard library is a module with one or more named
2 coroutines that take the machines:
2
2 ```python
2 async def cluster(vms: Machines) -> None: ...
2 async def test(vms: Machines) -> None: ...
2 ```
2
2 Several scripts then run in order against one set of guests, which is how
2 `recipes/kubernetes.py` becomes a thing anybody can put in front of their
2 own test.
2
2 **A script as an argument is also how iteration gets fast.** Today the
2 script is baked into the `run` wrapper, so editing one line of Python
2 re-evaluates Nix. A path on the command line does not. The sandboxed
2 build still names the script as an input, because the check has to be
2 reproducible — so both doors exist, and only one of them is fast.
2
2 The type check has to follow. `typeCheck` runs over the script because
2 `mkTest` names it (`lib.nix:252`). A script that arrives on a command
2 line needs its own door into the same check.
1
1 ## Area 1 — steering a run
1
1 Landed as `d36934d1` and **provisional**: it may be replaced by the knobs
1 in the open questions below.
1
1 `mkTest` takes `impurities`, a list of environment variable *names*. The
1 spec carries the list. It never carries a value, so no store path moves
1 with what a caller sets, and `nix build` needs no `--impure`. The runner
1 reads the names into `vms.env`. A script passes what it chooses into a
1 guest with `succeed(..., env = {...})`.
1
1 Two properties, both measured:
1
1 - The derivation path is the same with the variable set and unset.
1 - A sandboxed run prints `UML_TEST_IMPURITY=unset` and takes the test's
1   own default. A run by hand reads the value.
1
1 The command line reaches a script as `vms.argv`. It did not before: the
1 parser was strict and exited 2.
1
1 **The cost of this shape.** A steer only works outside the sandbox. So
1 `NIXKUBE_UML_SCENARIOS=x nix build --file . umlTest` stops working when
1 nixkube drops its `builtins.getEnv`, and `nix run --file . umlTest.run`
1 replaces it. See the open questions.
1
2 **A CLI changes where this lives.** Parsing the command line moves out of
2 `load_spec` and into the CLI, and `vms.argv` may stop being the right
2 name for it once a run takes several scripts. The property to keep is the
2 one above: Nix declares names, never values.
1
1 ## Area 2 — output
1
1 The sandboxed path is already right. The by-hand path keeps nothing that
1 anybody can find.
1
2 Decided: `$out` when sandboxed, and a directory the caller names
2 otherwise, through a flag or an environment variable. So the question is
2 no longer whether to default to `./uml-out/`, and `lib.nix:330` stands —
2 nothing writes to a directory nobody chose.
1
2 Open: whether the two layouts are identical, whether a named directory
2 that already holds a run is overwritten or given a second entry, and
2 whether the directory records the steer the run was given. A log that
2 does not say which case it ran is a log that cannot be read a week later.
1
1 ## Area 3 — streams
1
1 This is not a filter on top of the current output. It is what the current
1 output becomes.
1
1 There are four streams today, interleaved into one and told apart by a
1 prefix. Each guest's console. The harness's own events. What the test
1 prints. The timings.
1
1 If the runner owns the process, it can keep them apart:
1
1 - Each stream goes to its own file in the output directory. A guest's
1   console is already buffered in `Machine._history`.
1 - The terminal gets a filtered view of the same events.
1 - The MCP server reads the events, not the text.
1
1 That last point is why this belongs with item 4 and not on its own. An
1 agent that greps a log is an agent that breaks when a message changes.
1
2 ## Area 5 — copying and streaming out of a guest
2
2 Copying is nearly free already: `/artifacts` is a host directory, so a
2 guest that writes a file has already delivered it. What is missing is the
2 short way to say it, and the case where the thing to collect is not a
2 file the test wrote — a journal, a unit's log, a directory.
2
2 Streaming is the harder half, and it hits a real limit. The agent runs
2 one command at a time and each command runs to completion
2 (`agent.py:10`). So `journalctl -f` cannot be followed while the test
2 does anything else, and a slow command reports nothing until it ends.
2
2 Three ways out, and this is a question for the design:
2
2 - A second channel to each guest, so a stream does not take the one the
2   commands use.
2 - An agent that starts a command, returns a handle, and serves output as
2   it arrives.
2 - Nothing in the agent: the guest writes to `/artifacts` and the host
2   follows the file. Cheapest, and it covers most of what a test wants.
2
2 The last one is worth trying first because it needs no protocol change.
1
1 ## Area 4 — sessions, breakpoints, MCP
1
1 Issue #10 holds the idea. Two notes from the code:
1
1 - Running Python in a guest is one more `exposed_` method. The dispatch is
1   already generic.
1 - The hard part is the session. `run_test` tears the guests down whichever
1   way the run ends, so the state that a failure creates is gone before
1   anything can look at it.
1
1 A hold-on-failure mode is the first step, and it is useful with no MCP
1 server at all. Reboots (#11) want the same ownership: a machine that comes
1 back is a machine something outside it drives.
1
2 ## Area 6 — an unsandboxed run with the internet off
2
2 A sandboxed run has no network, and that is the environment most of these
2 tests are written for. Iterating on such a test outside the sandbox
2 changes the environment under it: the guest suddenly resolves names and
2 reaches a cache, so a test that would fail in the check passes by hand.
2
2 So the runner needs a switch that gives an unsandboxed guest the same
2 empty network a sandboxed one has. Then a failure reproduces where it can
2 be looked at.
2
2 Open: what the switch turns off. Not starting passt at all is the
2 simplest, and it also removes the host-to-guest forwards that a test may
2 use to reach an API server. Keeping passt and cutting only the uplink
2 keeps the forwards. The second is probably what is wanted, and it is more
2 work.
1
1 ## What "any machine" means
1
1 UML is Linux only. QEMU without KVM is slow enough to be a different
1 promise. The doc needs one line that says where the claim stops, or
1 "any machine" means "any of Carl's machines" and nobody finds out until
1 they try.
1
1 ## Open questions
1
2 1. **What does a script export?** One coroutine, or several named ones
2    the CLI can pick from and order? Named phases make a standard library
2    composable and make a breakpoint something you can name. One coroutine
2    is what exists.
2 2. **Do several scripts share one set of guests?** Assumed yes. Then:
2    does a failure in the first stop the rest, and does each get its own
2    section in the report?
2 3. **Where does the standard library live?** Inside `uml_runner` as
2    importable recipes, or as scripts in this repository that a caller
2    names on the command line? The first is versioned with the runner. The
2    second is copy-able and easier to fork.
2 4. **Does the spec name the scripts, or does the command line?** Both, in
2    the end — the sandboxed build must name them to stay reproducible, and
2    the fast door must not. The question is which one is the primary.
1 5. **Does `nix build` ever take a steer?** Today: no, by design. The cost
1    is nixkube's `NIXKUBE_UML_SCENARIOS`.
1 6. **Environment variable names, or declared knobs?** `impurities = [ "X" ]`
1    is stringly, and it is a separate mechanism from `argv`. A declared knob
1    is one mechanism for both:
1
1    ```nix
1    knobs.scenarios = { type = "string"; default = ""; };
1    ```
1
1    It reaches the script as `vms.knobs.scenarios`. A caller sets it with
1    `--scenarios=csi` or with an environment variable. It has a default the
1    run prints, and the sandbox uses that default rather than an empty
1    string that means two things.
2 7. **How does a stream leave a guest?** See area 5. The `/artifacts`
2    answer needs no protocol change; the other two do.
2 8. **What does "no internet" turn off?** See area 6.
1
1 ## Issues
1
1 - #14 steering a run (the landed part)
1 - #15 output directory, and the stdout filter
1 - #10 MCP server and interactive sessions
1 - #11 reboots
