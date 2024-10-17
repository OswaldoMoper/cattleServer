# cattleServer
This is an application to convert Example server from *PET* to *CATTLE*

## OS Setup

1. Make sure the Example server is part of the knownhosts list by logging in via ssh.

    ```
    ssh <username>@<Server IP address>
    ```

2. If this successfully logs you into the server, the server is now part of the knownhosts list. Otherwise, you should receive a response like the following to which you will respond with a yes.
    
    ```
    The authenticity of host '<Server IP address> (<Server IP address>)' can't be established.
    ED25519 key fingerprint is SHA256:<sha256 fingerprint>.
    This key is not known by any other names.
    Are you sure you want to continue connecting (yes/no/[fingerprint])?
    ```

## Nix Setup

1. If you haven't already, [install Nix](https://nixos.org/download/)
	* On POSIX systems, this is usually `curl -L https://nixos.org/nix/install | sh`
2. Run `nix flake show --allow-import-from-derivation` to verify that the flake can be read correctly by nix.
3. Build libraries: `nix build`
4. You can use this like a installation flake, or you can copy `configuration/cattleServer.nix` in your `configuration.nix` and add the flake to your inputs.

If you have trouble, refer to the [Nix Reference Manual](https://hydra.nixos.org/build/275163694/download/1/manual/introduction.html) for additional detail.

## CattleServer Setup

* By default, cattleServer uses the `config/cattleServer.json` file to operate.
* You can modify the `config/cattleServer.json` file at any time, for this you can check the `config/documentation.json` and `config/example.json` files.
* If you delete the `config/cattleServer.json` file, CattleServer will recreate that file with the same settings from `config/example.json`