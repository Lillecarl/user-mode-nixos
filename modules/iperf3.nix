# An iperf3 server, for measuring what a segment between two guests can
# actually carry.  Tests drive the client side themselves over the agent,
# so there is nothing here to schedule or wait for.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.iperf3-server;
in
{
  options.services.iperf3-server = {
    enable = lib.mkEnableOption "the iperf3 server";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5201;
      description = "Port iperf3 listens on.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Also puts iperf3 on the agent's PATH, so a test can run the client.
    environment.systemPackages = [ pkgs.iperf3 ];

    systemd.services.iperf3-server = {
      description = "iperf3 server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.iperf3} --server --port ${toString cfg.port}";
        Restart = "always";
      };
    };
  };
}
