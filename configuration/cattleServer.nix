# An example of consuming this flake. Copying it is no longer necessary --
# the module is exported as inputs.cattleServer.nixosModules.default -- so
# this exists to show the shape, not to be imported.
#
# The values are documentation names and addresses (RFC 2606, RFC 5737): a
# real deployment keeps its own in the private configuration that consumes
# this flake.
{ config, inputs, ... }: {

  imports = [ inputs.cattleServer.nixosModules.default ];

  services.cattleServer = {
    enable = true;

    # The configuration names a host, a database and a key path, so it comes
    # from a secret rather than from `settings`, which renders into the Nix
    # store where anyone on the host can read it.
    settingsFile = config.age.secrets.cattleServerConfig.path;

    # A host's public key is not a secret, so it can be declared even when the
    # rest of the configuration is encrypted. With it the service never has to
    # trust whatever the network answers, and `strict` becomes usable.
    knownHostsSeed = [
      "backup.example.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExa"
    ];
  };

  # The same thing without a secret, which suits a test host and not a real
  # one, since all of this ends up in the Nix store:
  #
  # services.cattleServer.settings = {
  #   localHost     = { hostName = "backup-puller";
  #                     userName = "cattleserver";
  #                     userHome = "/var/lib/cattleServer"; };
  #   hostKeyPolicy = "strict";
  #   apps = [
  #     {
  #       appConfig      = { name = "example-daily"; structure = "/upload"; };
  #       databaseConfig = { name = "postgres"; structure = "yesod-project"; };
  #       serviceConfig  = {
  #         remoteHost      = { hostName = "backup.example.org";
  #                             userName = "admin";
  #                             userHome = "/home/admin"; };
  #         keyDirectory    = { name = "example-ed25519"; structure = "/run/agenix"; };
  #         portNumber      = 22;
  #         backupFrequency = { unit = "Hours"; times = 8; };
  #         deleteFrequency = { unit = "Days"; times = 10; };
  #       };
  #     }
  #   ];
  # };
}
