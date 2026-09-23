"""What Nix hands the runner, as a validated model.

A free-form dict is what the old spec was, and every field it carried had
to be read defensively at the point of use.  A model says the shape once,
rejects a malformed spec with the field named, and gives pyright
something to check a caller against.

Nothing here decides anything.  The spec is **input**: the runner and the
recipes are built once and do not move when it does, so a value in here
never reaches an image, a database or a derivation the guests depend on.
See `docs/design/running-anywhere.md`, area 0a.
"""

from __future__ import annotations

import json
from pathlib import Path

from pydantic import BaseModel, Field


class PhaseSpec(BaseModel):
    """One unit of work, declared in Nix and ordered there.

    The list arrives sorted: `lib.toposort` runs during evaluation, so a
    cycle is an evaluation error and never reaches this.  `after` is kept
    anyway, because it is what says which phases a failure takes with it.
    """

    name: str
    script: Path
    after: list[str] = Field(default_factory=list)


class Spec(BaseModel):
    """A whole run, as evaluating the module system produced it."""

    machines: list[dict]
    """Passed to `uml_runner.MachineSpec.from_json` untouched.  Modelling
    it twice would be two places to change when a backend gains a flag."""

    phases: list[PhaseSpec] = Field(default_factory=list)
    settings: dict = Field(default_factory=dict)
    knobs: dict[str, str] = Field(default_factory=dict)

    kernel: Path | None = None
    bridge: Path | None = None
    passt: Path | None = None
    qemu: Path | None = None
    qemuImg: Path | None = None  # noqa: N815 -- Nix writes it, so Nix spells it
    virtiofsd: Path | None = None

    @classmethod
    def read(cls, path: Path) -> Spec:
        return cls.model_validate(json.loads(path.read_text()))

    def toolchain(self) -> dict:
        """The toolchain fields, as `uml_runner.Toolchain` wants them.

        Only what this run's backend needs is set; naming a store path is
        what makes Nix build it, so a UML run carries no QEMU and a QEMU
        run carries no kernel.
        """
        named = ("kernel", "bridge", "passt", "qemu", "qemuImg", "virtiofsd")
        return {
            key: str(value)
            for key in named
            if (value := getattr(self, key)) is not None
        }
