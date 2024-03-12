{ pkgs, inputs, ... }: {

  nixpkgs.overlays = [
    (_: _: {
      cattleServer-wrapper = inputs.cattleServer.packages.x86_64-linux.cattleServer-wrapper;
    })
  ];

  systemd.services.cattleServer = {
    description = "cattleServer";
    enable = true;
    wantedBy = [ "multi-user.target" ];
    after = [ "network.service" "local-fs.target" ];
    serviceConfig = {
      Type = "simple";
      User = "<user>";
      WorkingDirectory = "/home/<user>/cattleServer";
      ExecStart = ''${pkgs.cattleServer-wrapper}/bin/cattleServer-wrapped'';
      ExecStop = "";
      # Restart = "always";
    };
  };
}
