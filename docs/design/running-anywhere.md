# Running anywhere: a design, not a plan

**Status: draft. Nothing here is decided.** Carl and Claude write this
together. It exists because the next four changes cement the shape of the
runner, and some of them replace what is there now.

## The goal

> Everything that is not a push to a registry or a cache must run on any
> machine, through user-mode-nixos.

CI then stops being the place where the answer lives. It becomes one more
caller of a thing a developer runs the same way.

Four things must be easy for that to be true:

1. Tell a run what to do from outside. Environment variables first, so a
   run does one case of a suite instead of all of it.
2. Get the output back. A known directory on the host, easy to grep.
3. Maybe: filter what reaches the terminal. The same stream also goes to
   the output directory.
4. Later: an MCP server. An agent starts a run, sets a breakpoint, gets a
   notification, and runs Python inside the guest.

## What exists today

Facts, with the file that holds them.

- A test is a derivation. `mkTest` builds `attempt`, which never fails, and
  a second derivation reads its `status` file (`lib.nix:328`).
- The test script is the program. The derivation runs
  `python3 ${script} --spec ${spec}`, and the script ends with
  `run_test(test)` at module level (`tests/artifacts.py`).
- `run_test` boots the guests, runs the coroutine, and tears the guests
  down in a `finally` (`harness.py:113`). Every run ends the same way.
- There are two entry points, not one. `run-uml` boots one guest from
  command-line arguments (`cli.py`). `run_test` boots a spec.
- `/artifacts` is a host directory, one per guest, on both backends
  (`harness.py:142`, `modules/image.nix:60`, `modules/qemu.nix:140`).
- A sandboxed run writes `log`, `report.json`, `status` and `artifacts/`
  into `$out`. A run by hand writes the artifacts to a new temporary
  directory and keeps nothing else (`harness.py:135`, `lib.nix:305`).
- Everything the run prints goes to one stream, with a prefix: `[test]`,
  `[uml]`, `[time]`, and `[<machine>]` for a guest's console
  (`machine.py:398`).
- The agent takes a method call over a serial line, and the dispatch is
  generic: `exposed_<name>` (`arpyc.py:29`).

## The decision that cements the rest

**Who owns the process: the test script, or the runner?**

Today the script owns it. `run_test(test)` is the last line of the file,
so importing a test starts it. Everything else follows from that. The
command line belongs to the script. The output directory is chosen by an
environment variable, because nothing else is in a position to choose it.
A run ends when the coroutine returns.

Items 3 and 4 both need the other shape:

- A session that holds after a failure cannot be a `finally` in the
  function that also *is* the program.
- A breakpoint is a pause in a loop somebody else drives.
- An agent that starts a run wants to name a test, not to execute a file.
- Two tests in one session need one owner of the guests.

So the question is whether a test becomes a coroutine that a runner
imports and drives:

```python
# today: the script is the program
run_test(test)

# the other shape: the script exports, the runner drives
async def test(vms: Machines) -> None: ...
```

The second shape moves the command line, the output directory and the
impurity reading out of the script and into the runner. It also merges
`cli.py` and `harness.py`, which are two doors to the same thing.

Cost: every existing test changes its last line, and every caller outside
this repository does too — nixkube and easykubenix both drive `mkTest`.

**Nothing below is settled until this is.**

## Area 1 — steering a run

Landed as `d36934d1` and **provisional**: it may be replaced by the knobs
in the open questions below.

`mkTest` takes `impurities`, a list of environment variable *names*. The
spec carries the list. It never carries a value, so no store path moves
with what a caller sets, and `nix build` needs no `--impure`. The runner
reads the names into `vms.env`. A script passes what it chooses into a
guest with `succeed(..., env = {...})`.

Two properties, both measured:

- The derivation path is the same with the variable set and unset.
- A sandboxed run prints `UML_TEST_IMPURITY=unset` and takes the test's
  own default. A run by hand reads the value.

The command line reaches a script as `vms.argv`. It did not before: the
parser was strict and exited 2.

**The cost of this shape.** A steer only works outside the sandbox. So
`NIXKUBE_UML_SCENARIOS=x nix build --file . umlTest` stops working when
nixkube drops its `builtins.getEnv`, and `nix run --file . umlTest.run`
replaces it. See the open questions.

## Area 2 — output

The sandboxed path is already right. The by-hand path keeps nothing that
anybody can find.

The proposal is one directory per run by hand, holding what the sandbox
holds. `./uml-out/<test>/` is the candidate default. It reverses a
deliberate decision (`lib.nix:305`): a run by hand records only when it is
asked to, so that nothing writes to a directory nobody chose.

Open: whether the two layouts must be identical, whether a run gets an id
so that two runs do not overwrite each other, and whether the directory
records the steer it was given. A log that does not say which case it ran
is a log that cannot be read a week later.

## Area 3 — streams

This is not a filter on top of the current output. It is what the current
output becomes.

There are four streams today, interleaved into one and told apart by a
prefix. Each guest's console. The harness's own events. What the test
prints. The timings.

If the runner owns the process, it can keep them apart:

- Each stream goes to its own file in the output directory. A guest's
  console is already buffered in `Machine._history`.
- The terminal gets a filtered view of the same events.
- The MCP server reads the events, not the text.

That last point is why this belongs with item 4 and not on its own. An
agent that greps a log is an agent that breaks when a message changes.

## Area 4 — sessions, breakpoints, MCP

Issue #10 holds the idea. Two notes from the code:

- Running Python in a guest is one more `exposed_` method. The dispatch is
  already generic.
- The hard part is the session. `run_test` tears the guests down whichever
  way the run ends, so the state that a failure creates is gone before
  anything can look at it.

A hold-on-failure mode is the first step, and it is useful with no MCP
server at all. Reboots (#11) want the same ownership: a machine that comes
back is a machine something outside it drives.

## What "any machine" means

UML is Linux only. QEMU without KVM is slow enough to be a different
promise. The doc needs one line that says where the claim stops, or
"any machine" means "any of Carl's machines" and nobody finds out until
they try.

## Open questions

1. **Who owns the process?** See above. Everything else waits on it.
2. **Does `nix build` ever take a steer?** Today: no, by design. The cost
   is nixkube's `NIXKUBE_UML_SCENARIOS`.
3. **Environment variable names, or declared knobs?** `impurities = [ "X" ]`
   is stringly, and it is a separate mechanism from `argv`. A declared knob
   is one mechanism for both:

   ```nix
   knobs.scenarios = { type = "string"; default = ""; };
   ```

   It reaches the script as `vms.knobs.scenarios`. A caller sets it with
   `--scenarios=csi` or with an environment variable. It has a default the
   run prints, and the sandbox uses that default rather than an empty
   string that means two things.
4. **The output directory default.** Opt-in, or `./uml-out/` by default?
5. **One entry point or two?** `run-uml` and `run_test` do the same work
   from different arguments.

## Issues

- #14 steering a run (the landed part)
- #15 output directory, and the stdout filter
- #10 MCP server and interactive sessions
- #11 reboots
