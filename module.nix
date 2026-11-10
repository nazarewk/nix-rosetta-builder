{
  # configuration
  image,
  linuxSystem,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    boolToString
    escapeShellArg
    mkAfter
    mkBefore
    mkDefault
    mkEnableOption
    mkForce
    mkIf
    mkMerge
    mkOption
    optionalAttrs
    optionalString
    types
    ;
in
{
  options.nix-rosetta-builder = {
    enable = (mkEnableOption "Nix Rosetta Linux builder") // {
      default = true;
    };

    potentiallyInsecureExtraNixosModule = mkOption {
      type = types.attrs;
      default = { };
      description = ''
        Extra NixOS configuration module to pass to the VM.
        The VM's default configuration allows it to be securely used as a builder.  Some extra
        configuration changes may endager this security and allow compromised deriviations into the
        host's Nix store.  Care should be taken to think through the implications of any extra
        configuration changes using this option.  When in doubt, please open a GitHub issue to
        discuss (additional, restricted options can be added to support safe configurations).
      '';
    };

    speedFactor = mkOption {
      type = types.int;
      default = 1;
      description = ''
        The relative speed factor of the builder.
        This sets the speed factor in the `nix.buildMachines` specification,
        which affects how Nix distributes build tasks to this machine.
      '';
    };

    cores = mkOption {
      type = types.int;
      default = 8;
      description = ''
        The number of CPU cores allocated to the VM.
        This also sets the maximum number of jobs allowed for the
        builder in the `nix.buildMachines` specification.
      '';
    };

    diskSize = mkOption {
      type = types.str;
      default = "100GiB";
      description = ''
        The size of the disk image for the VM.
      '';
    };

    memory = mkOption {
      type = types.str;
      default = "6GiB";
      description = ''
        The amount of memory to allocate to the VM.
      '';
      example = "8GiB";
    };

    onDemand = mkOption {
      type = types.bool;
      default = false;
      description = ''
        By default, the VM will run all the time as a daemon in the background.  This allows Linux
        builds to start right away, but means the VM is always consuming RAM (and a bit of CPU).

        Alternatively, this option will cause the VM to run only "on-demand": when not in use the VM
        will not be running.  Any Linux build will cause it to automatically start up
        (blocking/pausing the build for several seconds until the VM boots) and after a period of
        time/hours without any active Linux builds, the VM will power itself off.
      '';
    };

    onDemandLingerMinutes = mkOption {
      type = types.ints.positive;
      default = 180;
      description = ''
        If onDemand=true, this specifies the number of minutes of inactivity before the VM will
        power itself off.
      '';
    };

    permitNonRootSshAccess = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Allow regular, non-root users to SSH into the VM with `ssh rosetta-builder`.

        By default, regular users can `nix build` using the VM without any extra permissions (since
        it's configured as a remote builder), but they can only SSH directly into it with
        `sudo ssh rosetta-builder`.
      '';
    };

    port = mkOption {
      type = types.int;

      # `nix.linux-builder` uses 31022:
      # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/nix/linux-builder.nix#L199
      # Use a similar, but different one:
      default = 31122;

      description = ''
        The SSH port used by the VM.
      '';
    };

    workingDir = mkOption {
      type = types.str;
      default = "/var/lib/${(import ./constants.nix).name}";
      description = ''
        The working directory for the VM. This is where the VM's data, SSH keys,
        and disk image are stored. Defaults to `/var/lib/rosetta-builder`.

        Change this to relocate the guest data to an external or larger volume.
        The directory is created automatically by the daemon.

        ⚠️ Changing this option destroys the existing guest VM. The daemon
        detects a working-directory change (via the generated lima.yaml) and
        runs `limactl delete --force` then `limactl create` — the guest's own
        Nix store is lost and must be rebuilt.
      '';
    };

    sshProtocol = mkOption {
      type = types.enum [
        "ssh"
        "ssh-ng"
      ];
      default = "ssh-ng";
      description = ''
        The SSH protocol to use for remote builds.
        Options are "ssh" (legacy) or "ssh-ng" (newer protocol with better performance).
      '';
    };

    mode = mkOption {
      type = types.enum [
        "ephemeral"
        "standalone"
      ];
      default = "ephemeral";
      description = ''
        How the guest's NixOS system is delivered.

        - `ephemeral` (upstream behaviour): the system is baked into the disk image and the image's
          store path is part of `lima.yaml`. Any guest configuration change therefore changes the
          generated yaml, and the daemon runs `limactl delete --force` + `create`. The guest's disk
          and `/nix/store` are discarded — fine for a pure build cache, which is what this VM is.

        - `standalone`: the image is only the bootstrap. `lima.yaml` carries a **stable** image
          path (`workingDir/image.qcow2`), so a new image does not change the yaml and does not
          recreate a running guest. The guest's system is exposed as
          `nix-rosetta-builder.guest.system` and applied in place with
          `nix-rosetta-builder.guest.switch`, so the disk and the store survive updates. The guest
          user gains passwordless sudo, which `switch-to-configuration` needs.

          A guest already running in `ephemeral` mode keeps its old disk when the mode flips: the
          yaml changes once, so the daemon recreates it that one time, and from then on updates are
          in place.
      '';
    };

    guest.system = mkOption {
      type = types.package;
      readOnly = true;
      description = ''
        The guest's NixOS system closure. `nix build` it, then run
        `nix-rosetta-builder.guest.switch` as root to copy it into the guest and switch to it.
      '';
    };

    guest.image = mkOption {
      type = types.package;
      readOnly = true;
      description = ''
        The bootstrap disk image (a qcow2) for a NEW guest.

        `mode = "standalone"` keeps this out of the host's closure on purpose: the running guest is
        updated in place, and the image is only read by `limactl create`. Build it on demand and
        install it with `nix-rosetta-builder.guest.installImage`.
      '';
    };

    guest.installImage = mkOption {
      type = types.package;
      readOnly = true;
      description = ''
        A script that builds `guest.image` and points the stable image path at it. Run it as root
        before the first guest creation, or whenever the bootstrap image should be refreshed. It
        does not touch a running guest.
      '';
    };

    guest.switch = mkOption {
      type = types.package;
      readOnly = true;
      description = ''
        A script that copies `guest.system` into the running guest and runs
        `switch-to-configuration switch` there. Run it as root (`sudo`), because only root may SSH
        into the guest by default. A kernel or initrd change still needs a reboot *inside* the
        guest; lima keeps the same VM, so the disk and store survive.
      '';
    };
  };

  config =
    let
      inherit (import ./constants.nix)
        name
        linuxHostName
        linuxUser
        sshKeyType
        sshHostPrivateKeyFileName
        sshHostPublicKeyFileName
        sshUserPrivateKeyFileName
        sshUserPublicKeyFileName
        ;

      debugInsecurely = false; # enable root access in VM and debug logging

      imageWithFinalConfig = image.override {
        inherit debugInsecurely;
        onDemand = cfg.onDemand;
        onDemandLingerMinutes = cfg.onDemandLingerMinutes;
        potentiallyInsecureExtraNixosModule = cfg.potentiallyInsecureExtraNixosModule;
        allowInPlaceUpdates = cfg.mode == "standalone";
      };

      cfg = config.nix-rosetta-builder;
      daemonName = "${name}d";
      daemonSocketName = "Listener";

      # `sysadminctl -h` says role account UIDs (no mention of service accounts or GIDs) should be
      # in the 200-400 range `mkuser`s README.md mentions the same:
      # https://github.com/freegeek-pdx/mkuser/blob/b7a7900d2e6ef01dfafad1ba085c94f7302677d9/README.md?plain=1#L413-L437
      # Determinate's `nix-installer` (and, I believe, current versions of the official one) uses a
      # variable number starting at 350 and up:
      # https://github.com/DeterminateSystems/nix-installer/blob/6beefac4d23bd9a0b74b6758f148aa24d6df3ca9/README.md?plain=1#L511-L514
      # Meanwhile, new macOS versions are installing accounts that encroach from below.
      # Try to fit in between:
      darwinGid = 349;
      darwinUid = darwinGid;

      darwinGroup = builtins.replaceStrings [ "-" ] [ "" ] name; # keep in sync with `name`s format
      darwinUser = "_${darwinGroup}";
      linuxSshdKeysDirName = "linux-sshd-keys";

      sshGlobalKnownHostsFileName = "ssh_known_hosts";
      sshHost = name; # no prefix because it's user visible (in `sudo ssh '${sshHost}'`)
      sshHostKeyAlias = "${sshHost}-key";
      workingDirPath = cfg.workingDir;

      gidSh = escapeShellArg (toString darwinGid);
      groupSh = escapeShellArg darwinGroup;
      groupPathSh = escapeShellArg "/Groups/${darwinGroup}";

      uidSh = escapeShellArg (toString darwinUid);
      userSh = escapeShellArg darwinUser;
      userPathSh = escapeShellArg "/Users/${darwinUser}";

      workingDirPathSh = escapeShellArg workingDirPath;

      # In `standalone` mode the yaml must not mention the image's store path: a new image would
      # change it, the daemon's `cmp` would fail, and the guest (with its store) would be recreated.
      # A stable path inside `workingDir` is repointed just before `limactl create`, which copies the
      # image into the instance's `basedisk` anyway, so repointing it later is harmless.
      imageFileName = "image.qcow2";
      imageLocation =
        if cfg.mode == "standalone" then
          "${workingDirPath}/${imageFileName}"
        else
          "${imageWithFinalConfig}/${imageWithFinalConfig.passthru.filePath}";
      imageStorePath = "${imageWithFinalConfig}/${imageWithFinalConfig.passthru.filePath}";

      vmYaml = (pkgs.formats.yaml { }).generate "${name}.yaml" {
        # Prevent ~200MiB unused nerdctl-full*.tar.gz download
        # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/instance/start.go#L43
        containerd.user = false;

        cpus = cfg.cores;

        disk = cfg.diskSize;

        images = [
          {
            location = imageLocation;
          }
        ];

        memory = cfg.memory;

        mounts = [
          {
            # order must match `sshdKeysVirtiofsTag`s suffix
            location = "${workingDirPath}/${linuxSshdKeysDirName}";
          }
        ];

        rosetta.enabled = true;

        ssh = {
          launchdSocketName = optionalString cfg.onDemand daemonSocketName;
          localPort = cfg.port;
        };
      };
    in
    mkMerge [
      (mkIf (!cfg.enable) {
        # This `postActivation` was chosen in particiular because it's one of the system level (as
        # opposed to user level) ones that's been set aside for customization:
        # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/system/activation-scripts.nix#L121-L125
        # And of those, it's the one that's executed after `activationScripts.launchd` which stops
        # the VM:
        # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/system/activation-scripts.nix#L58-L66
        # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/system/activation-scripts.nix#L66-L75
        system.activationScripts.postActivation.text =
          # apply "before" to work cooperatively with any other modules using this activation script
          mkBefore ''
            if [ -d ${workingDirPathSh} ] ; then
              printf >&2 'removing working directory %s...\n' ${workingDirPathSh}
              rm -rf ${workingDirPathSh}
            fi

            if uid="$(id -u ${userSh} 2>'/dev/null')" ; then
              if [ "$uid" -ne ${uidSh} ] ; then
                printf >&2 \
                  '\e[1;31merror: existing user: %s has unexpected UID: %s\e[0m\n' \
                  ${userSh} \
                  "$uid"
                exit 1
              fi
              printf >&2 'deleting user %s...\n' ${userSh}
              dscl . -delete ${userPathSh}
            fi
            unset 'uid'

            if primaryGroupId="$(dscl . -read ${groupPathSh} 'PrimaryGroupID' 2>'/dev/null')" ; then
              if [[ "$primaryGroupId" != *\ ${gidSh} ]] ; then
                printf >&2 \
                  '\e[1;31merror: existing group: %s has unexpected %s\e[0m\n' \
                  ${groupSh} \
                  "$primaryGroupId"
                exit 1
              fi
              printf >&2 'deleting group %s...\n' ${groupSh}
              dscl . -delete ${groupPathSh}
            fi
            unset 'primaryGroupId'
          '';
      })
      (mkIf cfg.enable {
        # The guest's system closure and the in-place switch helper. Both are cheap to evaluate and
        # only built when a consumer asks for them.
        nix-rosetta-builder.guest.system = imageWithFinalConfig.toplevel;

        nix-rosetta-builder.guest.switch = pkgs.writeShellApplication {
          name = "${name}-guest-switch";
          runtimeInputs = [
            pkgs.nix
            pkgs.openssh
          ];
          text = ''
            set -eu

            system=${escapeShellArg "${imageWithFinalConfig.toplevel}"}

            printf >&2 'copying %s to the guest...\n' "$system"
            nix copy --no-check-sigs --to ${escapeShellArg "ssh-ng://${sshHost}"} "$system"

            printf >&2 'switching the guest to %s...\n' "$system"
            # `$system` must expand here, on the client, so the remote command is built locally.
            # shellcheck disable=SC2029
            ssh ${escapeShellArg sshHost} \
              "sudo nix-env -p /nix/var/nix/profiles/system --set $system && sudo $system/bin/switch-to-configuration switch"

            printf >&2 'guest switched. A kernel or initrd change needs a reboot inside the guest: ssh %s sudo reboot\n' ${escapeShellArg sshHost}
          '';
        };

        nix-rosetta-builder.guest.image = imageWithFinalConfig;

        nix-rosetta-builder.guest.installImage = pkgs.writeShellApplication {
          name = "${name}-guest-install-image";
          runtimeInputs = [
            pkgs.coreutils
          ];
          text = ''
            set -eu

            image=${escapeShellArg imageStorePath}
            target=${escapeShellArg imageLocation}

            printf >&2 'installing %s -> %s\n' "$target" "$image"
            mkdir -p "$(dirname "$target")"
            ln -sfn "$image" "$target.tmp"
            mv -f "$target.tmp" "$target"
          '';
        };

        environment.etc."ssh/ssh_config.d/100-${sshHost}.conf".text = ''
          Host "${sshHost}"
            GlobalKnownHostsFile "${workingDirPath}/${sshGlobalKnownHostsFileName}"
            Hostname localhost
            HostKeyAlias "${sshHostKeyAlias}"
            Port "${toString cfg.port}"
            StrictHostKeyChecking yes
            User "${linuxUser}"
            IdentityFile "${workingDirPath}/${sshUserPrivateKeyFileName}"
        '';

        launchd.daemons."${daemonName}" = {
          path = [
            pkgs.coreutils
            pkgs.diffutils
            pkgs.findutils
            pkgs.gnugrep
            (pkgs.lima.overrideAttrs (old: {
              src = pkgs.fetchFromGitHub {
                owner = "cpick";
                repo = "lima";
                rev = "afbfdfb8dd5fa370547b7fc64a16ce2a354b1ff0";
                hash = "sha256-tCildZJp6ls+WxRAbkoeLRb4WdroBYn/gvE5Vb8Hm5A=";
              };

              vendorHash = "sha256-I84971WovhJL/VO/Ycu12qa9lDL3F9USxlt9rXcsnTU=";
            }))
            pkgs.openssh

            pkgs.darwin.DarwinTools
          ];

          script =
            let
              darwinUserSh = escapeShellArg darwinUser;
              linuxHostNameSh = escapeShellArg linuxHostName;
              linuxSshdKeysDirNameSh = escapeShellArg linuxSshdKeysDirName;
              sshGlobalKnownHostsFileNameSh = escapeShellArg sshGlobalKnownHostsFileName;
              sshHostKeyAliasSh = escapeShellArg sshHostKeyAlias;
              sshHostPrivateKeyFileNameSh = escapeShellArg sshHostPrivateKeyFileName;
              sshHostPublicKeyFileNameSh = escapeShellArg sshHostPublicKeyFileName;
              sshKeyTypeSh = escapeShellArg sshKeyType;
              sshUserPrivateKeyFileNameSh = escapeShellArg sshUserPrivateKeyFileName;
              sshUserPublicKeyFileNameSh = escapeShellArg sshUserPublicKeyFileName;
              vmNameSh = escapeShellArg "${name}-vm";
              vmYamlSh = escapeShellArg vmYaml;
            in
            ''
              set -e
              set -u

              umask 'g-w,o='
              chmod 'g-w,o=x' .

              # must be idempotent in the face of partial failues
              # the `find` test must fail if the user private key was readable but should no longer be
              cmp -s ${vmYamlSh} .lima/${vmNameSh}/lima.yaml && \
              limactl list -q 2>'/dev/null' | grep -q ${vmNameSh} && \
              find ${sshUserPrivateKeyFileNameSh} \
                -perm '-go=r' -exec ${boolToString cfg.permitNonRootSshAccess} '{}' '+' \
              2>'/dev/null' && \
              true || {
                rm -f ${sshUserPrivateKeyFileNameSh} ${sshUserPublicKeyFileNameSh}
                ssh-keygen \
                  -C ${darwinUserSh}@darwin -f ${sshUserPrivateKeyFileNameSh} -N "" -t ${sshKeyTypeSh}

                rm -f ${sshHostPrivateKeyFileNameSh} ${sshHostPublicKeyFileNameSh}
                ssh-keygen \
                  -C root@${linuxHostNameSh} -f ${sshHostPrivateKeyFileNameSh} -N "" -t ${sshKeyTypeSh}

                mkdir -p ${linuxSshdKeysDirNameSh}
                mv \
                  ${sshUserPublicKeyFileNameSh} ${sshHostPrivateKeyFileNameSh} \
                  ${linuxSshdKeysDirNameSh}

                echo ${sshHostKeyAliasSh} "$(cat ${sshHostPublicKeyFileNameSh})" \
                >${sshGlobalKnownHostsFileNameSh}

                limactl delete --force ${vmNameSh}

                ${optionalString (cfg.mode == "standalone") ''
                  # The yaml points at this stable path. It is populated by
                  # `nix-rosetta-builder.guest.installImage`, NOT by the host's closure, so a host
                  # switch never builds the bootstrap image.
                  if [ ! -e ${escapeShellArg imageLocation} ]; then
                    printf >&2 \
                      'error: %s is missing. Build and install the bootstrap image first: %s\n' \
                      ${escapeShellArg imageLocation} \
                      ${escapeShellArg "${name}-guest-install-image"}
                    exit 1
                  fi
                ''}

                # must be last so `limactl list` only now succeeds
                limactl create --name=${vmNameSh} ${vmYamlSh}
              }

              # outside the block so both new and old installations end up with the same permissions
              chmod 'go+r' ${sshGlobalKnownHostsFileNameSh}

              # outside the block so non-root access may be enabled without recreating VM
              ${optionalString cfg.permitNonRootSshAccess ''
                chmod 'go+r' ${sshUserPrivateKeyFileNameSh}
              ''}

              exec limactl start ${optionalString debugInsecurely "--debug"} --foreground ${vmNameSh}
            '';

          serviceConfig =
            {
              KeepAlive = !cfg.onDemand;

              Sockets."${daemonSocketName}" = optionalAttrs cfg.onDemand {
                SockFamily = "IPv4";
                SockNodeName = "localhost";
                SockServiceName = toString cfg.port;
              };

              UserName = darwinUser;
              WorkingDirectory = workingDirPath;
            }
            // optionalAttrs debugInsecurely {
              StandardErrorPath = "/tmp/${daemonName}.err.log";
              StandardOutPath = "/tmp/${daemonName}.out.log";
            };
        };

        nix = {
          buildMachines = [
            {
              inherit (cfg) speedFactor;
              hostName = sshHost;
              maxJobs = cfg.cores;
              protocol = cfg.sshProtocol;
              supportedFeatures = [
                "benchmark"
                "big-parallel"
                "kvm"
                "nixos-test"
              ];
              systems = [
                linuxSystem
                "x86_64-linux"
              ];
            }
          ];

          distributedBuilds = mkForce true;
          settings.builders-use-substitutes = mkDefault true;
        };

        # `users.users` cannot create a service account and cannot create an empty home directory so do
        # it manually in an activation script.  This `extraActivation` was chosen in particiular because
        # it's one of the system level (as opposed to user level) ones that's been set aside for
        # customization:
        # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/system/activation-scripts.nix#L121-L125
        # And of those, it's the one that's executed latest but still before
        # `activationScripts.launchd` which needs the group, user, and directory in place:
        # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/system/activation-scripts.nix#L58-L66
        system.activationScripts.extraActivation.text =
          # apply "after" to work cooperatively with any other modules using this activation script
          mkAfter ''
            printf >&2 'setting up group %s...\n' ${groupSh}

            if ! primaryGroupId="$(dscl . -read ${groupPathSh} 'PrimaryGroupID' 2>'/dev/null')" ; then
              printf >&2 'creating group %s...\n' ${groupSh}
              dscl . -create ${groupPathSh} 'PrimaryGroupID' ${gidSh}
            elif [[ "$primaryGroupId" != *\ ${gidSh} ]] ; then
              printf >&2 \
                '\e[1;31merror: existing group: %s has unexpected %s\e[0m\n' \
                ${groupSh} \
                "$primaryGroupId"
              exit 1
            fi
            unset 'primaryGroupId'


            printf >&2 'setting up user %s...\n' ${userSh}

            if ! uid="$(id -u ${userSh} 2>'/dev/null')" ; then
              printf >&2 'creating user %s...\n' ${userSh}
              dscl . -create ${userPathSh}
              dscl . -create ${userPathSh} 'PrimaryGroupID' ${gidSh}
              dscl . -create ${userPathSh} 'NFSHomeDirectory' ${workingDirPathSh}
              dscl . -create ${userPathSh} 'UserShell' '/usr/bin/false'
              dscl . -create ${userPathSh} 'IsHidden' 1
              dscl . -create ${userPathSh} 'UniqueID' ${uidSh} # must be last so `id` only now succeeds
            elif [ "$uid" -ne ${uidSh} ] ; then
              printf >&2 \
                '\e[1;31merror: existing user: %s has unexpected UID: %s\e[0m\n' \
                ${userSh} \
                "$uid"
              exit 1
            fi
            unset 'uid'


            printf >&2 'setting up working directory %s...\n' ${workingDirPathSh}
            mkdir -p ${workingDirPathSh}
            chown ${userSh}:${groupSh} ${workingDirPathSh}
          '';
      })
    ];
}
