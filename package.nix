{
  nixpkgs,
  linuxSystem,
  debugInsecurely ? false, # enable auto-login and passwordless sudo to root
  potentiallyInsecureExtraNixosModule ? { },
  onDemand ? false, # enable launchd socket activation
  onDemandLingerMinutes ? 180, # poweroff after 3 hours of inactivity
  withRosetta ? true,
  allowInPlaceUpdates ? false, # passwordless sudo for the guest user, for `switch-to-configuration`
}:

let
  imageConfig = nixpkgs.lib.nixosSystem {
    system = linuxSystem;
    modules = [
      ./guest.nix
      {
        nix-rosetta-builder.guest = {
          inherit
            debugInsecurely
            onDemand
            onDemandLingerMinutes
            withRosetta
            allowInPlaceUpdates
            ;
        };
      }
      # Pin the guest's `nixpkgs` registry entry to the same nixpkgs the image is built from.
      { nix.registry.nixpkgs.flake = nixpkgs; }
      potentiallyInsecureExtraNixosModule
    ];
  };

  image = imageConfig.config.system.build.images.qemu-efi;
in
# `//` keeps `override`, so the darwin module can specialise this for its own options and still get
# a `toplevel` that matches the overridden image.
image // {
  # The guest's system closure. `mode = "standalone"` on the host copies this into the running VM
  # and switches to it, instead of baking a new image and recreating the guest.
  toplevel = imageConfig.config.system.build.toplevel;
}
