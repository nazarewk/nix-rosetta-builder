# The guest's NixOS configuration, as a standalone module.
#
# Two consumers share it:
#
#   * `package.nix` bakes it into the bootstrap disk image (`mode = "ephemeral"` on the host);
#   * `flake.nixosModules.default` exposes it, so an adopter can declare the VM as an ordinary
#     `nixosConfigurations.<name>` and update it in place with `nixos-rebuild switch --target-host`
#     (`mode = "standalone"` on the host), keeping the guest's disk and `/nix/store`.
#
# The options mirror what `package.nix` used to take as arguments, so the darwin module can pass
# them through without duplicating any configuration.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nix-rosetta-builder.guest;

  inherit (import ./constants.nix)
    linuxHostName
    sshHostPrivateKeyFileName
    sshUserPublicKeyFileName
    ;

  inherit (lib)
    escapeShellArg
    optionalAttrs
    optionals
    ;

  sshdKeys = "sshd-keys";
  sshDirPath = "/etc/ssh";
  sshHostPrivateKeyFilePath = "${sshDirPath}/${sshHostPrivateKeyFileName}";
in
{
  options.nix-rosetta-builder.guest = {
    linuxUser = lib.mkOption {
      type = lib.types.str;
      default = (import ./constants.nix).linuxUser;
      description = ''
        The unprivileged account the host SSHes in as, and the account the builder advertises.
      '';
    };

    debugInsecurely = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable console autologin and passwordless sudo to root. For debugging only.
      '';
    };

    onDemand = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Power the guest off after `onDemandLingerMinutes` of inactivity. The host turns this on when
        its own `onDemand` option is set.
      '';
    };

    onDemandLingerMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = ''
        Minutes of inactivity before the guest powers itself off when `onDemand` is set.
      '';
    };

    withRosetta = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Mount the host's Rosetta directory share, so the guest can run `x86_64-linux` binaries.
      '';
    };

    allowInPlaceUpdates = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Grant `linuxUser` passwordless sudo.

        An in-place update copies the new system closure into the guest and runs
        `switch-to-configuration` there, which needs root. The host's `mode = "standalone"` sets
        this automatically; a standalone `nixosConfigurations.<name>` declaration must set it
        explicitly.
      '';
    };
  };

  config = {
    boot = {
      kernelParams = [ "console=tty0" ];

      loader = {
        efi.canTouchEfiVariables = true;
        systemd-boot.enable = true;
      };
    };

    documentation.enable = false;

    fileSystems = {
      # Defaults for a standalone `nixosConfigurations.<name>` declaration. The image module
      # (`system.build.images.qemu-efi`) defines `device` and `fsType` for the same two mounts at
      # normal priority, so it wins when the same module bakes the bootstrap image; `options` is
      # only defined here.
      "/" = lib.mkDefault {
        device = "/dev/disk/by-label/nixos";
        fsType = "ext4";
        options = [
          "discard"
          "noatime"
        ];
      };
      "/boot" = lib.mkDefault {
        device = "/dev/disk/by-label/ESP";
        fsType = "vfat";
        options = [
          "discard"
          "noatime"
          "umask=0077"
        ];
      };
    };

    networking.hostName = linuxHostName;

    nix = {
      channel.enable = false;

      # The fleet's clients and builders run Lix, and the `ssh-ng` protocol version is negotiated
      # between the client's `nix` and the guest's `nix-store --serve`. A guest on plain Nix (2.34
      # at the time of writing) answers a Lix 2.95 client with "protocol mismatch", so every farm
      # connection fails before a build is dispatched.
      package = pkgs.lix;

      settings = {
        auto-optimise-store = true;
        experimental-features = [
          "flakes"
          "nix-command"
        ];
        min-free = "5G";
        max-free = "7G";
        trusted-users = [ cfg.linuxUser ];
      };
    };

    security = {
      sudo = {
        enable = cfg.debugInsecurely || cfg.allowInPlaceUpdates;
        wheelNeedsPassword = !(cfg.debugInsecurely || cfg.allowInPlaceUpdates);
      };
    };

    services = {
      getty = optionalAttrs cfg.debugInsecurely { autologinUser = cfg.linuxUser; };

      logind.settings.Login = optionalAttrs cfg.onDemand {
        IdleAction = "poweroff";
        IdleActionSec = "${toString cfg.onDemandLingerMinutes}minutes";
      };

      openssh = {
        enable = true;
        hostKeys = [ ]; # disable automatic host key generation

        settings = {
          HostKey = sshHostPrivateKeyFilePath;
          PasswordAuthentication = false;
        };
      };
    };

    system = {
      disableInstallerTools = true;
      stateVersion = "24.05";
    };

    # macOS' Virtualization framework's virtiofs implementation will grant any guest user access
    # to mounted files; they always appear to be owned by the effective UID and so access cannot
    # be restricted.
    # To protect the guest's SSH host key, the VM is configured to prevent any logins (via
    # console, SSH, etc) by default.  This service then runs before sshd, mounts virtiofs,
    # copies the keys to local files (with appropriate ownership and permissions), and unmounts
    # the filesystem before allowing SSH to start.
    # Once SSH has been allowed to start (and given the guest user a chance to log in), the
    # virtiofs must never be mounted again (as the user could have left some process active to
    # read its secrets).  This is prevented by `unitconfig.ConditionPathExists` below.
    systemd.services."${sshdKeys}" =
      let
        # Lima labels its virtiofs folder mounts counting up:
        # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/vz/vm_darwin.go#L568
        # So this suffix must match `vmYaml.mounts.location`s order:
        sshdKeysVirtiofsTag = "mount0";

        sshdKeysDirPath = "/var/${sshdKeys}";
        sshAuthorizedKeysUserFilePath = "${sshDirPath}/authorized_keys.d/${cfg.linuxUser}";
        sshdService = "sshd.service";
      in
      {
        before = [ sshdService ];
        description = "Install sshd's host and authorized keys";
        enableStrictShellChecks = true;
        path = [
          pkgs.mount
          pkgs.umount
        ];
        requiredBy = [ sshdService ];

        script =
          let
            sshAuthorizedKeysUserFilePathSh = escapeShellArg sshAuthorizedKeysUserFilePath;
            sshAuthorizedKeysUserTmpFilePathSh = escapeShellArg "${sshAuthorizedKeysUserFilePath}.tmp";
            sshHostPrivateKeyFileNameSh = escapeShellArg sshHostPrivateKeyFileName;
            sshHostPrivateKeyFilePathSh = escapeShellArg sshHostPrivateKeyFilePath;
            sshUserPublicKeyFileNameSh = escapeShellArg sshUserPublicKeyFileName;
            sshdKeysDirPathSh = escapeShellArg sshdKeysDirPath;
            sshdKeysVirtiofsTagSh = escapeShellArg sshdKeysVirtiofsTag;
          in
          ''
            # must be idempotent in the face of partial failues

            mkdir -p ${sshdKeysDirPathSh}
            mount \
              -t 'virtiofs' \
              -o 'nodev,noexec,nosuid,ro' \
              ${sshdKeysVirtiofsTagSh} \
              ${sshdKeysDirPathSh}

            mkdir -p "$(dirname ${sshHostPrivateKeyFilePathSh})"
            (
              umask 'go='
              cp ${sshdKeysDirPathSh}/${sshHostPrivateKeyFileNameSh} ${sshHostPrivateKeyFilePathSh}
            )

            mkdir -p "$(dirname ${sshAuthorizedKeysUserTmpFilePathSh})"
            cp \
              ${sshdKeysDirPathSh}/${sshUserPublicKeyFileNameSh} \
              ${sshAuthorizedKeysUserTmpFilePathSh}
            chmod 'a+r' ${sshAuthorizedKeysUserTmpFilePathSh}

            umount ${sshdKeysDirPathSh}
            rmdir ${sshdKeysDirPathSh}

            # must be last so only now `unitConfig.ConditionPathExists` triggers
            mv ${sshAuthorizedKeysUserTmpFilePathSh} ${sshAuthorizedKeysUserFilePathSh}
          '';

        serviceConfig.Type = "oneshot";

        # see comments on this service and in its `script`
        unitConfig.ConditionPathExists = "!${sshAuthorizedKeysUserFilePath}";
      };

    users = {
      # console and (initial) SSH logins are purposely disabled
      # see: `systemd.services."${sshdKeys}"`
      allowNoPasswordLogin = true;

      mutableUsers = false;

      users."${cfg.linuxUser}" = {
        isNormalUser = true;
        extraGroups = optionals (cfg.debugInsecurely || cfg.allowInPlaceUpdates) [ "wheel" ];
      };
    };

    virtualisation.rosetta = optionalAttrs cfg.withRosetta {
      enable = true;

      # Lima's virtiofs label for rosetta:
      # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/vz/rosetta_directory_share_arm64.go#L15
      mountTag = "vz-rosetta";
    };
  };
}
