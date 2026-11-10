{
  description = "Lima-based, Rosetta 2-enabled, Apple silicon (macOS/Darwin)-hosted Linux builder";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      darwinSystem = "aarch64-darwin";
      linuxSystem = builtins.replaceStrings [ "darwin" ] [ "linux" ] darwinSystem;
    in
    {
      packages."${linuxSystem}" =
        let
          pkgs = nixpkgs.legacyPackages."${linuxSystem}";
        in
        rec {
          default = image;

          image = pkgs.callPackage ./package.nix {
            inherit linuxSystem nixpkgs;
            # Optional: override default argument values passed to the derivation.
            # Many can also be accessed through the module.
          };
        };

      devShells."${darwinSystem}".default =
        let
          pkgs = nixpkgs.legacyPackages."${darwinSystem}";
        in
        pkgs.mkShell {
          packages = [ pkgs.lima ];
        };

      darwinModules.default = import ./module.nix {
        inherit linuxSystem;
        image = self.packages."${linuxSystem}".image;
      };

      # The guest's NixOS configuration as a standalone module. Use it to declare the VM as an
      # ordinary `nixosConfigurations.<name>` and update it in place
      # (`nixos-rebuild switch --target-host`), instead of baking a new image per change:
      #
      #   nixosConfigurations.rosetta-builder = nixpkgs.lib.nixosSystem {
      #     system = "aarch64-linux";
      #     modules = [
      #       nix-rosetta-builder.nixosModules.default
      #       { nix-rosetta-builder.guest.allowInPlaceUpdates = true; }
      #     ];
      #   };
      nixosModules.default = ./guest.nix;
      nixosModules.guest = ./guest.nix;

      formatter."${darwinSystem}" = nixpkgs.legacyPackages."${darwinSystem}".nixfmt-rfc-style;
    };
}
