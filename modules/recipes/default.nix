# The standard library: work somebody else already wrote.
#
# A recipe is a module. It contributes a phase, the guest configuration
# that phase needs, and the knobs it reads -- so a consumer enables it in
# one line and gets all three, and overrides any of it the way they
# override any other option.
#
# That is the whole reason phases live in the module system rather than in
# a Python registry. A registry can share a function; it cannot also bring
# the systemd unit the function expects to find running.
#
# Adding one: a `.nix` here and a `.py` in `recipes/`, imported below.
{
  imports = [
    ./boot.nix
    ./journal.nix
  ];
}
