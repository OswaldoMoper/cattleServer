{
  description = "Nix flake for cattleServer";
  inputs = {
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    haskellNix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = inputs@{ self
                   , nixpkgs
                   , flake-utils
                   , haskellNix
                   , flake-compat
                   }:
    let
      overlays =
        [ haskellNix.overlay
          (final: prev: {
            cattleServer = final.haskell-nix.stackProject {
              src = final.haskell-nix.cleanSourceHaskell {
                src = ./.;
                name = "cattleServer";
              };
              shell.buildInputs = with pkgs; [
                stack
                ghcid
              ];
              shell.additional = hsPkgs: with hsPkgs; [ Cabal ];
            };
            cattleServer-wrapper = pkgs.writeShellApplication {
              name = "cattleServer-wrapped";
              runtimeInputs = [ self.packages.x86_64-linux.default ];
              text = ''
               cd /home/<user>/cattleServer
               ${self.packages.x86_64-linux.default}/bin/cattleServer
              '';
            };
          })
        ];
      pkgs = import nixpkgs { system = "x86_64-linux";
                              inherit overlays;
                              inherit (haskellNix) config;
                            };
      flake = pkgs.cattleServer.flake {};
    in flake-utils.lib.eachSystem [ "x86_64-linux" ] (system: flake // {
        packages = flake.packages // {
          default = flake.packages."cattleServer:exe:cattleServer";
          cattleServer-wrapper = pkgs.cattleServer-wrapper;
        };
        apps = flake.apps // { default = flake.apps."cattleServer:exe:cattleServer"; };
        legacyPackages = pkgs;
      });
  # --- Flake Local Nix Configuration ----------------------------
  nixConfig = {
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
    allow-import-from-derivation = "true";
  };
}