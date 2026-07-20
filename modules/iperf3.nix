{ config, pkgs, lib, ... }:
{
  options.services.iperf3-server = {
    enable = lib.mkEnableOption "iperf3 server";
    port = lib.mkOption {
      type = lib.types.int;
      default = 5201;
      description = "iperf3 listen port";
    };
  };

  options.services.iperf3-client = {
    peer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Peer IP to run iperf3 client against on boot";
    };
    duration = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "iperf3 test duration in seconds";
    };
  };

  options.services.speedtest = {
    enable = lib.mkEnableOption "speedtest-cli on boot";
  };

  config = lib.mkMerge [
    (lib.mkIf config.services.iperf3-server.enable {
      systemd.services.uml-rpyc-server.path = with pkgs; [ iperf3 ];

      systemd.services.iperf3-server = {
        description = "iperf3 server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "systemd-networkd.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.iperf3}/bin/iperf3 --server -p ${toString config.services.iperf3-server.port}";
          Restart = "always";
        };
      };
    })

    (lib.mkIf (config.services.iperf3-server.enable && config.services.iperf3-client.peer != null) {
      systemd.services.iperf3-client = {
        description = "iperf3 client -> ${config.services.iperf3-client.peer}";
        wantedBy = [ "multi-user.target" ];
        after = [ "iperf3-server.service" "network.target" "systemd-networkd.service" ];
        requires = [ "iperf3-server.service" ];
        serviceConfig.Type = "oneshot";
        path = [ pkgs.iputils ];
        script = ''
          exec >/dev/console 2>&1
          set -euo pipefail
          echo "=== IPERF3 CLIENT -> ${config.services.iperf3-client.peer} ==="
          echo "waiting for peer to be pingable..."
          for i in $(seq 1 30); do
            if ping -c1 -W1 ${config.services.iperf3-client.peer} >/dev/null 2>&1; then
              break
            fi
            sleep 1
          done
          echo "peer reachable, running iperf3..."
          ${pkgs.iperf3}/bin/iperf3 \
            -c ${config.services.iperf3-client.peer} \
            -p ${toString config.services.iperf3-server.port} \
            -t ${toString config.services.iperf3-client.duration} \
            ${lib.optionalString (config.services.iperf3-client.duration > 3) "--json"}
          echo "=== IPERF3 CLIENT DONE ==="
        '';
      };
    })

    (lib.mkIf config.services.speedtest.enable {
      systemd.services.uml-rpyc-server.path = with pkgs; [ speedtest-cli ];

      systemd.services.speedtest = {
        description = "speedtest-cli";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        serviceConfig.Type = "oneshot";
        script = ''
          exec >/dev/console 2>&1
          echo "=== SPEEDTEST ==="
          ${pkgs.speedtest-cli}/bin/speedtest-cli
          echo "=== SPEEDTEST DONE ==="
        '';
      };
    })
  ];
}
