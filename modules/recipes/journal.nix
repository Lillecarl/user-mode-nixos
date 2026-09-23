# Put every guest's journal on the host, after everything else has run.
{ config, lib, ... }:
let
  cfg = config.uml.recipes.journal;

  /*
    Every other enabled phase, so this one is last.

    `lib.attrNames config.phases` and not a hand-written list: a recipe
    cannot know what a consumer added, and a journal that runs before the
    interesting phase is a journal of a boot.

    Reading `config.phases` from inside a definition of `config.phases`
    is safe because only the *names* are read. The module system knows
    every key once the modules are merged, and none of the values here
    depend on this one.
  */
  others = lib.remove cfg.name (lib.attrNames config.phases);
in
{
  options.uml.recipes.journal = {
    enable = lib.mkEnableOption ''
      a last phase that writes each guest's journal into its /artifacts
      directory
    '';

    name = lib.mkOption {
      type = lib.types.str;
      default = "journal";
      description = "What the phase is called.";
    };
  };

  config = lib.mkIf cfg.enable {
    phases.${cfg.name} = {
      script = ../../recipes/journal.py;
      after = others;
      # Ordering only. This is the phase you want most on the run that
      # failed, and `after` alone would skip it for exactly that reason.
      always = true;
      description = "each guest's journal, on the host";
    };
  };
}
