{ self }:
{ config, lib, pkgs, ... }:

let
  inherit (lib) literalExpression mkEnableOption mkIf mkOption types;

  cfg = config.services.cattleServer;
  jsonFormat = pkgs.formats.json { };

  hostOpts = {
    options = {
      hostName = mkOption { type = types.str; description = "Host name or address."; };
      userName = mkOption { type = types.str; description = "Account to log in as."; };
      userHome = mkOption { type = types.str; description = "That account's home directory."; };
    };
  };

  routeOpts = {
    options = {
      name      = mkOption { type = types.str; };
      structure = mkOption { type = types.str; };
    };
  };

  unitTimeOpts = {
    options = {
      unit  = mkOption { type = types.enum [ "Hours" "Days" "Weeks" "Months" ]; };
      times = mkOption { type = types.ints.positive; };
    };
  };

  connectionOpts = {
    freeformType = jsonFormat.type;
    options = {
      remoteHost      = mkOption { type = types.submodule hostOpts; };
      keyDirectory    = mkOption {
        type = types.submodule routeOpts;
        description = ''
          Directory and base name of the SSH key. Both the private key and its
          .pub are read from there, so both have to be in the same directory.
        '';
      };
      portNumber      = mkOption { type = types.port; default = 22; };
      backupFrequency = mkOption { type = types.submodule unitTimeOpts; };
      deleteFrequency = mkOption { type = types.submodule unitTimeOpts; };
      hostKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''[ "ssh-ed25519 AAAAC3Nz..." ]'';
        description = ''
          Public keys of the remote host, installed into known_hosts as they
          are. Declaring them is what makes hostKeyPolicy = "strict" usable:
          the host's identity comes from here rather than from whatever the
          network answers.
        '';
      };
      hostKeyFingerprint = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU";
        description = "A scanned key must match this fingerprint to be trusted.";
      };
      keepAtLeast = mkOption {
        type = types.ints.unsigned;
        default = 2;
        description = ''
          How many backups have to survive whatever `deleteFrequency` would
          remove.

          Deletion goes by date and runs whether or not the backup before it
          succeeded, so on its own it will empty the directory after a week of
          failing backups. This is the floor that stops it. Two by default, so
          that a corrupt newest backup still leaves one behind it.

          Zero restores deletion that only looks at the calendar.
        '';
      };
    };
  };

  appOpts = {
    freeformType = jsonFormat.type;
    options = {
      appConfig = mkOption {
        type = types.submodule routeOpts;
        description = ''
          `name` identifies the application in the log, the backup directory
          and the marker the scheduler reads back. Renaming it makes the
          service lose track of the last backup and take one immediately.
        '';
      };
      databaseConfig = mkOption {
        type = types.submodule routeOpts;
        description = "`name` is the postgres role, `structure` the database.";
      };
      serviceConfig = mkOption { type = types.submodule connectionOpts; };
    };
  };

  settingsOpts = {
    freeformType = jsonFormat.type;
    options = {
      localHost = mkOption {
        type = types.submodule hostOpts;
        description = ''
          The machine pulling the backups. `userHome` is where they land, so
          it has to be writable by the service user.
        '';
      };
      knownHosts = mkOption {
        type = types.str;
        default = "${cfg.stateDir}/known_hosts";
        defaultText = literalExpression ''"''${config.services.cattleServer.stateDir}/known_hosts"'';
        description = ''
          The known_hosts file the service maintains. It defaults into the
          state directory rather than a home directory: a system user has no
          home worth writing to, and ProtectHome hides /home from the unit.
        '';
      };
      logDir = mkOption {
        type = types.str;
        default = "${cfg.stateDir}/cattleServer-Logs";
        defaultText = literalExpression ''"''${config.services.cattleServer.stateDir}/cattleServer-Logs"'';
        description = ''
          Holds the service log and one log per application. The service log
          is also the scheduler's state: it decides when the next backup is
          due by reading back its own success markers.
        '';
      };
      hostKeyPolicy = mkOption {
        type = types.enum [ "strict" "accept-new" ];
        default = "accept-new";
        description = ''
          What to do when a host is not in known_hosts yet.

          `accept-new` scans the host and adds what it answers, optionally
          checked against `hostKeyFingerprint`. `strict` never writes, so pair
          it with `hostKeys` or `knownHostsSeed`.

          Neither ever replaces an entry that is already there.
        '';
      };
      checkEvery = mkOption {
        type = types.ints.positive;
        default = 30;
        description = ''
          Minutes between two passes over the applications.

          This bounds how late a backup can be rather than how often one
          happens: each application has its own `backupFrequency`, and a pass
          only acts on the ones that are due. A pass that finds nothing due
          costs one log file read, so checking often is cheap.
        '';
      };
      startupDelay = mkOption {
        type = types.ints.unsigned;
        default = 30;
        description = ''
          Minutes to wait before the first pass.

          Zero makes the first pass happen at startup. On a machine with no
          log yet that means backing up immediately, since nothing records a
          previous backup -- worth knowing before pairing it with
          `Restart = "always"`.
        '';
      };
      apps = mkOption {
        type = types.listOf (types.submodule appOpts);
        default = [ ];
      };
    };
  };

  # types.nullOr defaults render as JSON null, which the service reads as an
  # absent field. Dropping them keeps the rendered file readable. filterAttrs
  # does not descend into lists, and `apps` is a list.
  prune = v:
    if lib.isList v then map prune v
    else if lib.isAttrs v && !lib.isDerivation v
    then lib.mapAttrs (_: prune) (lib.filterAttrs (_: x: x != null) v)
    else v;

  renderedSettings = jsonFormat.generate "cattleServer.json" (prune cfg.settings);

  usesCredential = cfg.settingsFile != null;
  configPath     = if usesCredential then "%d/config" else "${renderedSettings}";
  underVarLib    = lib.hasPrefix "/var/lib/" cfg.stateDir;

  seedFile = pkgs.writeText "cattleServer-known-hosts-seed"
    (lib.concatMapStrings (l: l + "\n") cfg.knownHostsSeed);
in
{
  options.services.cattleServer = {
    enable = mkEnableOption "the cattleServer backup daemon";

    package = mkOption {
      type = types.package;
      default =
        if pkgs ? cattleServer && lib.isDerivation pkgs.cattleServer
        then pkgs.cattleServer
        else self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = literalExpression "pkgs.cattleServer, or this flake's own package";
      description = ''
        Forcing the default pulls in the haskell.nix build, which needs
        import-from-derivation. That is on by default in Nix, so nixos-rebuild
        is unaffected, but `nix flake show`, `nix flake check` and restricted
        evaluation are not. Set this to a pre-built package to keep evaluation
        free of it.

        The fallback builds against this flake's pinned nixpkgs rather than
        yours, which is deliberate -- it avoids rebuilding GHC -- at the cost
        of a second nixpkgs in the closure.
      '';
    };

    user  = mkOption { type = types.str; default = "cattleserver"; };
    group = mkOption { type = types.str; default = "cattleserver"; };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/cattleServer";
      description = "Holds the known_hosts file the service maintains, and the logs.";
    };

    settings = mkOption {
      type = types.submodule settingsOpts;
      default = { };
      description = ''
        Contents of the configuration file. Rendered into the Nix store, which
        is world readable on the host, so use `settingsFile` for anything that
        should not be.
      '';
    };

    settingsFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "config.age.secrets.cattleServerConfig.path";
      description = ''
        Path to the configuration file at runtime, passed through a systemd
        credential. Takes precedence over `settings`, and is the option to use
        in production: the file names a host, a database and a key path.
      '';
    };

    knownHostsSeed = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ "example.org ssh-ed25519 AAAAC3Nz..." ]'';
      description = ''
        known_hosts lines installed on first start. Lets `strict` work without
        a manual first login, and composes with an encrypted `settingsFile`,
        since a host's public key is not a secret. Only written when the file
        does not exist yet, so it never clobbers what the service added.
      '';
    };

    extraReadWritePaths = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = ''
        Extra paths the unit may write to. The backup destination is
        `settings.localHost.userHome`, which is added automatically -- but it
        cannot be when `settingsFile` is used, because the module cannot read
        an encrypted file. Name it here in that case.
      '';
    };

    protectHome = mkOption {
      type = types.either types.bool (types.enum [ "read-only" "tmpfs" ]);
      default = true;
      description = ''
        Set to "read-only" if the SSH key or the backup destination has to
        stay under /home during a migration.
      '';
    };
  };

  config = mkIf cfg.enable {
    warnings = lib.optional (usesCredential && cfg.settings.apps != [ ])
      "services.cattleServer: settingsFile takes precedence, so settings.apps is ignored.";

    assertions = [
      {
        assertion = usesCredential || cfg.settings.apps != [ ];
        message = "services.cattleServer: set either settingsFile or settings.apps.";
      }
    ];

    users.users = mkIf (cfg.user == "cattleserver") {
      cattleserver = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.stateDir;
      };
    };
    users.groups = mkIf (cfg.group == "cattleserver") { cattleserver = { }; };

    systemd.tmpfiles.rules =
      lib.optional (!underVarLib) "d ${cfg.stateDir} 0700 ${cfg.user} ${cfg.group} - -";

    systemd.services.cattleServer = {
      description = "cattleServer backup daemon";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];
      path        = [ pkgs.openssh pkgs.coreutils ];

      environment.CATTLESERVER_CONFIG = configPath;

      # Guarded on the file not existing, so it never replaces an entry the
      # service added itself. preStart already runs as the service user.
      preStart = lib.optionalString (cfg.knownHostsSeed != [ ]) ''
        if [ ! -e ${lib.escapeShellArg cfg.settings.knownHosts} ]; then
          install -m 0600 ${seedFile} ${lib.escapeShellArg cfg.settings.knownHosts}
        fi
      '';

      serviceConfig = {
        Type             = "simple";
        ExecStart        = lib.getExe cfg.package;
        User             = cfg.user;
        Group            = cfg.group;
        # The first backup happens half an hour after start, so a restart loop
        # here is slow rather than hot.
        Restart          = "always";
        RestartSec       = "60s";
        WorkingDirectory = cfg.stateDir;
        UMask            = "0077";

        # The backup destination, the logs and the known_hosts file all
        # default under stateDir, but any of them can be pointed elsewhere.
        # None can be derived when the configuration is a credential, since
        # the module cannot read it -- hence extraReadWritePaths.
        # The "-" prefix marks a path systemd may skip when it does not exist.
        # The service creates its own log directory on first run, and a path
        # listed here that is missing fails the unit at step NAMESPACE before
        # anything runs -- which reads as a restart loop with no explanation.
        ReadWritePaths = lib.unique
          ([ cfg.stateDir ] ++ cfg.extraReadWritePaths
           ++ map (p: "-" + p) (lib.optionals (!usesCredential) [
                cfg.settings.localHost.userHome
                cfg.settings.logDir
                (builtins.dirOf cfg.settings.knownHosts)
              ]));

        NoNewPrivileges         = true;
        PrivateTmp              = true;
        PrivateDevices          = true;
        ProtectSystem           = "strict";
        ProtectHome             = cfg.protectHome;
        ProtectKernelTunables   = true;
        ProtectKernelModules    = true;
        ProtectControlGroups    = true;
        ProtectClock            = true;
        RestrictNamespaces      = true;
        RestrictSUIDSGID        = true;
        RestrictRealtime        = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        LockPersonality         = true;
        SystemCallArchitectures = "native";
        SystemCallFilter        = [ "@system-service" "~@privileged" "~@resources" ];
        CapabilityBoundingSet   = [ "" ];
        AmbientCapabilities     = [ "" ];
      }
      # StateDirectory= is relative to /var/lib, so it only applies when the
      # state directory is actually under it; systemd.tmpfiles covers the rest.
      // lib.optionalAttrs underVarLib {
        StateDirectory     = lib.removePrefix "/var/lib/" cfg.stateDir;
        StateDirectoryMode = "0700";
      }
      // lib.optionalAttrs usesCredential {
        LoadCredential = [ "config:${cfg.settingsFile}" ];
      };
    };
  };
}
