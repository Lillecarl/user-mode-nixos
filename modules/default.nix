{ config, pkgs, lib, ... }:
{
  boot.isContainer = true;

  networking.hostName = "umn";
  networking.useDHCP = false;

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };

  users.users.root.initialPassword = "";

  system.stateVersion = "25.05";

  documentation.enable = false;
  documentation.nixos.enable = false;
}
