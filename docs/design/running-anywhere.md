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
3 - **The runner never invokes Nix.** Not the CLI, not a library. Nix writes
3   a JSON spec and builds the images; the runner reads the file
3   (`harness.py:load_spec`). Checked: no `nix` subprocess anywhere in
3   `uml_runner`. So evaluating Nix would be a new power, not a replacement
3   for a shell-out.
4 - **What is built depends on the spec, and it must not.** Measured: adding
4   one plain string to `settings` moves seven derivations, including
4   `uml-root-image`. The cause is `lib.nix:241` — the settings file is
4   registered in the guest's Nix database, so the image's content follows
4   the file's hash. Nothing about a guest's image is different; only the
4   data handed to the run.
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
3
3 From the second round:
3
3 - **Python contributes one coroutine per script.** No phase names, no
3   decorators, no registry in Python.
3 - **Phases are declared in the NixOS module system**, and Nix orders
3   them. The module system already has the merging and ordering machinery,
3   and a consumer can reorder or drop a phase the way they override any
3   other option.
3 - **Recipes are scripts in this repository**, each with a submodule that
3   declares it. `recipes/kubernetes.py` beside the option that names it.
3 - **Knobs are module options**, resolved by a helper:
3   `envOrDefault = envvar: default:`. An environment variable that is unset
3   reads `""`, and so does `builtins.getEnv` under a pure evaluation, so
3   both cases fall through to the declared default.
3 - **nanopynix is the candidate evaluator**, so the runner can ask an
3   evaluation questions at will instead of being handed one JSON file.
4
4 From the third round:
4
4 - **Nothing that is built may depend on the spec.** The runner is a tool,
4   the way `pynix` is a tool: it reads a spec and acts on it. The recipe
4   scripts are the same. Neither is rebuilt because a knob moved.
5
5 From the fourth round:
5
5 - **The module system is the only source.** Evaluating it produces three
5   things: the image specs, a wrapper that runs the runner unsandboxed,
5   and a wrapper that runs it sandboxed.
5 - **The CLI evaluates that same module system** to get the spec it runs.
5 - **A phase contributes configuration as well as a script.** Much of what
5   a phase is will be systemd units, plus whatever coordinates several
5   nodes.
1
4 ## Area 0a — the spec is input, not an ingredient
4
4 The rule: **the runner and the recipes are built once and do not move
4 when the spec does.** The runner is a tool, the way `pynix` is a tool. A
4 tool reads its input; it is not rebuilt by it.
4
4 Today that is false, and the number says how false. Adding one plain
4 string to a test's `settings` rebuilds seven derivations, and one of them
4 is `uml-root-image` — the guest's disk. Nothing inside the guest is
4 different. The cause is one line:
4
4 ```nix
4 boot.uml.nixDatabase.extraRoots =
4   lib.optional (settings != { }) "${settingsFile}";   # lib.nix:241
4 ```
4
4 The settings file is registered in the guest's Nix database, so the image
4 follows the file's hash. The registration exists for a good reason:
4 `settings` may carry store paths, and Nix inside the guest must know
4 them, or it calls the path invalid and goes looking for a substituter.
4
4 So the fix is to separate the two things `settings` does today:
4
4 - **Paths** a guest must be able to resolve. These belong to what is
4   built, and registering their closure is right.
4 - **Values** a run is given — a knob, a selection, a tag. These are data.
4   They must reach the runner without touching an image, a database or a
4   derivation the guests depend on.
4
4 Get that right and the cost of an evaluation-time knob collapses to an
4 evaluation and a small JSON file. That is most of what makes question 6
4 a question, so it is worth doing first.
4
4 **The obvious way to split them does not work.** Asking the JSON for its
4 string context looks like it names the paths, and it does not:
4
4 ```nix
4 builtins.getContext (builtins.toJSON { a = "${pkgs.hello}"; })
4 # => { "/nix/store/...-hello-2.12.3.drv" = { outputs = [ "out" ]; }; }
4 ```
4
4 A derivation in a value gives its **`.drv`**, not its output path. The
4 guest needs the output. So context alone cannot build the list, although
4 it looks like it can — checked, because the failure would be silent: the
4 database would register a path nothing in the guest ever asks for, and
4 the real one would be invalid at run time.
4
4 Three candidates, none tried:
4
4 - Scan the JSON text for store paths. The text already holds the output
4   path; only the context names the `.drv`. Crude, and it is what Nix's
4   own scanner does.
4 - Write the sorted path list to its own file and build the database from
4   that. Two settings that differ only in a plain value then produce the
4   same file, so the image does not move.
4 - Make the author name the paths. No discovery, no trap, and the doc
4   comment at `lib.nix` says why that was rejected once already: a path
4   that is missed is not a build error, it is a guest that goes looking
4   for a substituter.
4
5 ## Area 0c — one evaluation, three outputs
5
5 Evaluating the module system gives the image specs, an unsandboxed
5 wrapper and a sandboxed wrapper. The CLI evaluates the same thing when it
5 is run by hand.
5
5 The gain is real and it is the one worth naming first: today `.run` and
5 the sandboxed `attempt` are written separately, and every asymmetry
5 between them is a bug somebody meets later — no log by hand, no report by
5 hand, `$@` promised and not delivered. Two outputs of one evaluation
5 cannot drift that way, **as long as they are the same script generated
5 twice with a flag**, and not two scripts that happen to agree today.
5
5 Five things to watch.
5
5 **1. Typed options make the path problem disappear.** Question 10 asks
5 how the guests learn which store paths the spec mentions. That question
5 only exists because `settings` is a free-form attrset, so the paths have
5 to be discovered. Options have types. A `types.package` or `types.path`
5 option *is* a path; a `types.str` option is not. The module system
5 already knows the difference, so nothing has to scan anything and the
5 `.drv` trap above never arises. This is a better answer than the sorted
5 list file, and it comes free with the direction already chosen.
5
5 **2. Every run pays for an evaluation.** `.run` is a store path today, so
5 running it costs nothing but the boot. A CLI that evaluates pays the
5 NixOS module system on every run, for every guest, and it lands on the
5 case the whole design is for: change one line, run again.
5
5 Measured, warm store, `nix eval` of the test's `drvPath`:
5
5 | what | seconds |
5 | --- | --- |
5 | this repo's smallest guest (`impure`) | 2.7 |
5 | this repo's Kubernetes guest (`k8s`) | 4.8 |
5 | nixkube's `umlTest`, the largest real consumer | 9.3 |
5
5 Acceptable. The smallest guest here takes 6.9s to boot, and nixkube's
5 test runs for about twenty minutes, so the evaluation is a minority of
5 even the shortest run. An evaluation cache is an optimisation, not a
5 requirement. Worth re-measuring on a cold store, which these numbers are
5 not.
5
5 **3. The CLI now builds, and a build can fail.** Evaluating gives
5 derivations; something must realise them. So a failure that used to
5 happen before the runner started now happens inside it, and its progress
5 and its errors need somewhere to go. That is new surface, and it is the
5 part users see first when something is wrong.
5
5 **4. The CLI needs the same door as `nix`.** `uml run mytest` has to find
5 the file to evaluate, the nixpkgs to evaluate it against, and the
5 arguments to pass. `nix build --file . <attr>` answers all three. The CLI
5 should answer them the same way and with the same spelling, or people
5 learn two conventions for one thing.
5
5 **5. Selecting a phase must not rebuild a guest.** A phase contributes
5 configuration, so enabling one changes what is built — correct. But
5 *choosing which phases to run* is the thing this design exists to make
5 fast. So the rule has to be: every declared phase's configuration is
5 always built, and selection happens at run time. A guest carries the
5 units for all its phases and runs the ones it is asked to. Selecting
5 otherwise would rebuild the image for every selection, which is the cost
5 area 0a exists to remove.
5
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
3
3 **The Python side is as small as it can be.** One coroutine per script:
3
3 ```python
3 async def test(vms: Machines) -> None: ...
3 ```
3
3 Nothing else is exported and nothing runs on import. The module is data
3 until the runner calls it.
3
3 **The ordering lives in Nix.** A phase is an option, not a Python name:
3
3 ```nix
3 uml.phases.cluster = {
3   script = ./recipes/kubernetes.py;
3   after = [ "boot" ];
3 };
3 uml.phases.check = {
3   script = ./mytest.py;
3   after = [ "cluster" ];
3 };
3 ```
3
3 That buys what a Python registry cannot. A consumer reorders a phase,
3 replaces one, or drops it with `lib.mkForce`, the same way they override
3 any NixOS option. A recipe can require another by name. And the order is
3 visible without running anything.
3
3 Open: whether `after` is the right spelling, or whether the list merging
3 the module system already has (`mkBefore`, `mkAfter`, `mkOrder`) is
3 enough. The second is less to invent and less to explain.
2
2 **A script as an argument is also how iteration gets fast.** Today the
2 script is baked into the `run` wrapper, so editing one line of Python
2 re-evaluates Nix. A path on the command line does not. The sandboxed
2 build still names the script as an input, because the check has to be
2 reproducible — so both doors exist, and only one of them is fast.
3
3 Phases in Nix put that in tension: if the phase list names the scripts,
3 then changing a script means re-evaluating after all. The likely answer
3 is that the CLI can override one phase's script with a path, so the fast
3 door stays open for the file being worked on.
2
2 The type check has to follow. `typeCheck` runs over the script because
2 `mkTest` names it (`lib.nix:252`). A script that arrives on a command
2 line needs its own door into the same check.
3
3 ## Area 0b — Nix as a library, not a file
3
3 The runner is handed one JSON file today. Everything it can ever know was
3 decided when that file was written.
3
3 With nanopynix the runner evaluates instead. It opens a session, asks for
3 the attribute the caller named, and reads the phases, the knobs, the
3 guests and the paths out of the evaluation as it needs them.
3
3 What that buys:
3
3 - One command. `uml run mytest` evaluates, builds what it needs and
3   boots, with no `nix build` first and no store path to paste.
3 - Questions asked late. A breakpoint that wants to know which phase comes
3   next, or an MCP tool that lists what can be run, asks the evaluation
3   rather than a file that was written before either existed.
3 - Knobs resolve where they are declared, so an environment variable can
3   change what is *built*, not only what the script does at run time.
3
3 What it costs:
3
3 - The runner gains a large dependency. Today `uml_runner` needs rpyc and
3   qemu-qmp and nothing else.
3 - **The sandboxed path must not evaluate.** Inside `nix build` everything
3   is already decided, the sandbox has no network, and a second evaluation
3   would be a different answer from the one the derivation was built from.
3   So the spec file stays, and the two doors differ: the CLI evaluates,
3   the check reads. That is a seam to keep honest.
3 - Bounds "any machine" further. See below.
1
1 ## Area 1 — steering a run
1
3 Landed as `d36934d1`. **This is now superseded** by knobs as module
3 options; the commit stays until the replacement exists, so that nothing
3 regresses in between.
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
3
3 **The knob shape makes the opposite trade, on purpose.** `envOrDefault`
3 reads the environment during evaluation, so a set variable changes the
3 derivation. That is the price of the thing it buys: a knob can choose a
3 phase order, a guest's memory or a different image, which no amount of
3 run-time reading can do.
3
3 Two consequences to hold on to:
3
4 - A set knob is a cache miss, and how much that costs depends entirely on
4   area 0a. Today it rebuilds the guest's disk image, measured. Once the
4   spec stops reaching what is built, it costs an evaluation and a small
4   JSON file, which is the right price.
3 - A variable left in a shell silently builds something that is not the
3   check. The run must print every knob, its value and where the value
3   came from — the environment or the default — before it boots anything.
3
3 Pure evaluation is what makes the default reliable: `builtins.getEnv`
3 returns `""` there, which is the same as unset, so a flake consumer and a
3 CI check both get the declared default with no special case.
3
4 Open, and it turns on area 0a: a knob that only changes what the script
4 *does* — one case out of a suite — costs a guest image today. Once the
4 spec stops reaching what is built, it costs an evaluation, and one kind
4 of knob is probably enough. See question 6.
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
3
3 With phases in Nix, a phase is also the natural unit here: each one gets
3 its own section in the report and its own span in the event stream.
2
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
3
3 Phases give a breakpoint a name. "Stop before `check`" is a thing a
3 caller can say without reading any Python, and an agent can list the
3 phases from the evaluation.
2
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
3
3 The evaluator narrows it again: a CLI that evaluates needs nanopynix
3 built for the machine it runs on. The check still runs anywhere Nix runs,
3 because the check reads a file.
1
1 ## Open questions
1
3 1. **How is a phase ordered?** An explicit `after` list, or the module
3    system's own list merging (`mkBefore`, `mkAfter`, `mkOrder`)? The
3    second invents nothing.
3 2. **Does a phase pick its guests?** A recipe that brings up a cluster
3    also wants to say what the guest must be. If a phase can contribute
3    NixOS configuration as well as a script, a recipe becomes one thing
3    instead of two that must be used together.
3 3. **What happens after a phase fails?** Stop, or run the rest anyway?
3    Stop is right for a dependency and wrong for two independent checks.
3 4. **Does the CLI let a phase's script be overridden with a path?** It is
3    what keeps iteration fast once the phase list lives in Nix.
1 5. **Does `nix build` ever take a steer?** Today: no, by design. The cost
1    is nixkube's `NIXKUBE_UML_SCENARIOS`.
3    Answered in part: with `envOrDefault`, `nix build` *does* take a
3    steer, and pays for it with a rebuild.
4 6. **One kind of knob, or two?** Mostly dissolved by area 0a. Once
4    nothing built depends on the spec, an evaluation-time knob costs an
4    evaluation, not a rebuild, and one kind is enough. Re-open only if an
4    evaluation turns out to be slow enough to notice.
2 7. **How does a stream leave a guest?** See area 5. The `/artifacts`
2    answer needs no protocol change; the other two do.
2 8. **What does "no internet" turn off?** See area 6.
3 9. **Does the sandboxed path keep the spec file?** Assumed yes — the
3    sandbox must not evaluate. Worth confirming, because it means two
3    doors into the same run for good.
5 10. **How does a guest learn about a store path in the spec?** Probably
5    answered: typed options. A `types.package` option is a path and a
5    `types.str` option is not, so nothing is discovered and nothing is
5    scanned. See area 0c. The sorted-list-file answer stays written down
5    in area 0a for the case where a free-form attrset survives somewhere.
5 11. **What does an evaluation cost per run?** Answered: 2.7s to 9.3s,
5    warm. Acceptable against a 6.9s boot and a twenty-minute test. See
5    area 0c for the table.
5 12. **Where do the CLI's build output and build failures go?** New
5    surface: realising a derivation moves inside the runner.
1
1 ## Issues
1
1 - #14 steering a run (the landed part)
1 - #15 output directory, and the stdout filter
1 - #10 MCP server and interactive sessions
1 - #11 reboots
