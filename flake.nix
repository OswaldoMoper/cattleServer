{
  description = "Nix flake for cattleServer";

  inputs = {
    haskellNix.url  = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, haskellNix }:
    let
      supportedSystems = [ "x86_64-linux" ];

      overlay = final: _prev: {
        cattleServer-project = final.haskell-nix.stackProject {
          src = final.haskell-nix.cleanSourceHaskell {
            src  = ./.;
            name = "cattleServer";
          };
          shell.buildInputs = [ final.stack final.ghcid final.openssh ];
          shell.additional  = hsPkgs: [ hsPkgs.Cabal ];
        };

        cattleServer =
          let
            exe = final.cattleServer-project.hsPkgs.cattleServer.components.exes.cattleServer;
          in
          final.runCommand "cattleServer"
            {
              nativeBuildInputs = [ final.makeWrapper ];
              meta = (exe.meta or { }) // { mainProgram = "cattleServer"; };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${exe}/bin/cattleServer $out/bin/cattleServer \
                --prefix PATH : ${final.lib.makeBinPath [ final.openssh final.rsync final.coreutils ]}
            '';
      };
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          inherit (haskellNix) config;
          overlays = [ haskellNix.overlay overlay ];
        };
        flake = pkgs.cattleServer-project.flake { };
      in
      flake // {
        packages = flake.packages // {
          default                = pkgs.cattleServer;
          cattleServer           = pkgs.cattleServer;
          cattleServer-unwrapped = flake.packages."cattleServer:exe:cattleServer";
        };
        apps = flake.apps // {
          default = {
            type    = "app";
            program = "${pkgs.cattleServer}/bin/cattleServer";
          };
        };
        legacyPackages = pkgs;
      })
    // {
      overlays.default          = overlay;
      nixosModules.cattleServer = import ./nix/module.nix { inherit self; };
      nixosModules.default      = self.nixosModules.cattleServer;
    };

  # --- Flake Local Nix Configuration ----------------------------
  nixConfig = {
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
    allow-import-from-derivation = "true";
  };
}
