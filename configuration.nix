# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

let
  sops-nix = builtins.fetchTarball {
    url = "https://github.com/Mic92/sops-nix/archive/master.tar.gz";
    # Pin the hash to avoid silent updates — get it by running:
    # nix-prefetch-url --unpack https://github.com/Mic92/sops-nix/archive/master.tar.gz
    sha256 = "0zxy0kfhhi0dq5jz0gkx9lb3m02a1gzkm86dvsga614kbair3wam";
  };
in
{

  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      "${sops-nix}/modules/sops" 
    ];
  environment.systemPackages = with pkgs; [
    sops
    iw
    iproute2
    git
    vim
    htop
    python3
  ];

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };



sops.secrets.wpa_supplicant = {
  sopsFile = ./secrets/wpa_supplicant.conf;
  format = "binary";
  path = "/etc/wpa_supplicant.conf";
  restartUnits = [ "wpa_supplicant-wlp0s20f3.service" ];
};

systemd.services."wpa_supplicant-wlp0s20f3" = {
#  after = [ "sops-install-secrets.service" ];
#  requires = [ "sops-install-secrets.service" ];

  serviceConfig.ExecStartPre = [
    "+${pkgs.iproute2}/bin/ip  link set wlp0s20f3 up"
    "+${pkgs.iw}/bin/iw dev wlp0s20f3 set power_save off"
  ];
};

 # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "andromeda"; # Define your hostname.

  # Configure network connections interactively with nmcli or nmtui.

  
networking = {

 
  interfaces.wlp0s20f3 = {
    useDHCP = false;

    ipv4.addresses = [{
      address = "192.168.2.185";
      prefixLength = 24;
    }];
  };
  defaultGateway = "192.168.2.1";
  nameservers = [ "1.1.1.1" "8.8.8.8" ];
};

networking.wireless = {
  enable = true;
  interfaces = [ "wlp0s20f3" ];
  # no secretsFile, no networks block — config comes entirely from the secret
};



#  networking.localCommands = ''
#sleep 2
#${pkgs.iproute2}/bin/ip addr add 102.168.2.185 dev wlp0s20f3 || true
#${pkgs.iproute2}/bin/ip route add default via 192.168.2.1 dev wlp0s20f3 || true
#'';


  services.prometheus = {
    enable = true;
    port = 9090;
    exporters.node = {
      enable = true;
      port = 9100;
      enabledCollectors = [ "systemd" ];
    };
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [{ targets = [ "localhost:9100" ]; }];
      }
    ];
  };

  services.grafana = {
    enable = true;
    settings.server = {
      http_addr = "0.0.0.0";
      http_port = 3000;
    };
    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [
        {
          name = "Prometheus";
          uid = "prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://localhost:9090";
          isDefault = true;
          orgId = 1;
        }
        {
          name = "Loki";
          uid = "loki";
          type = "loki";
          access = "proxy";
          url = "http://localhost:3100";
          orgId = 1;
        }
        ];
      };
      dashboards.settings = {
        apiVersion = 1;
        providers = [
          {
            name = "provisioned";
            options.path = pkgs.runCommand "grafana-dashboards" {} ''
              mkdir -p $out
              cp ${./grafana-dashboards/node-exporter-full.json} $out/node-exporter-full.json
              cp ${./grafana-dashboards/security-logs.json} $out/security-logs.json
            '';
          }
        ];
      };
    };
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false; # TODO deactivate
    settings.PermitRootLogin = "yes";
  };

  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
  };

  # Automate Nix Store cleanup
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Docker
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };
			
  services.logind.lidSwitch = "ignore";
# -----------------------------------------------------------------------------
# security

  # Kernel-level audit trail: exec, privilege escalation, sensitive file writes
  security.auditd.enable = true;
  security.audit.enable = true;
  security.audit.rules = [
    "-a exit,always -F arch=b64 -S execve"         # all command execution
    "-w /etc/passwd -p wa -k identity"              # user account changes
    "-w /etc/shadow -p wa -k identity"
    "-w /etc/sudoers -p wa -k sudoers"
    "-w /var/log/auth.log -p wa -k auth_log"
    "-a exit,always -F arch=b64 -S open,openat -F dir=/etc -F success=1 -k etc_access"
  ];

  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    # Escalating bans: each repeat offense multiplies the ban duration
    bantime-increment = {
      enable = true;
      multipliers = "1 2 4 8 16 32 64";
      maxtime = "168h"; # cap at 1 week
      overalljails = true;
    };
    jails = {
      sshd.settings = {
        enabled = true;
        port = "ssh";
        filter = "sshd";
        maxretry = 3;
        bantime = "2h";
      };
      nginx-http-auth.settings = {
        enabled = true;
        port = "http,https";
        filter = "nginx-http-auth";
      };
      nginx-botsearch.settings = {
        enabled = true;
        port = "http,https";
        filter = "nginx-botsearch";
        maxretry = 2;
      };
    };
  };

  # Log aggregation: ship systemd journal + auth logs into Loki for Grafana
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server.http_listen_port = 3100;
      ingester = {
        lifecycler = {
          address = "127.0.0.1";
          ring = {
            kvstore.store = "inmemory";
            replication_factor = 1;
          };
          final_sleep = "0s";
        };
        chunk_idle_period = "1h";
        max_chunk_age = "1h";
        chunk_target_size = 1048576;
        chunk_retain_period = "30s";
      };
      schema_config.configs = [{
        from = "2024-01-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = {
          prefix = "index_";
          period = "24h";
        };
      }];
      storage_config = {
        tsdb_shipper = {
          active_index_directory = "/var/lib/loki/tsdb-index";
          cache_location = "/var/lib/loki/tsdb-cache";
        };
        filesystem.directory = "/var/lib/loki/chunks";
      };
      limits_config = {
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
      };
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        compaction_interval = "10m";
      };
    };
  };

  # Allow promtail to read the systemd journal
  users.users.promtail = {
    isSystemUser = true;
    group = "promtail";
    extraGroups = [ "systemd-journal" ];
  };
  users.groups.promtail = {};

  systemd.services.promtail.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "promtail";
    Group = "promtail";
    StateDirectory = "promtail";
    ReadWritePaths = [ "/var/lib/promtail" ];
    ExecStartPre = lib.mkForce "";
  };

  services.promtail = {
    enable = true;
    configuration = {
      server = {
        http_listen_port = 9080;
        grpc_listen_port = 0;
      };
      positions.filename = "/var/lib/promtail/positions.yaml";
      clients = [{ url = "http://localhost:3100/loki/api/v1/push"; }];
      scrape_configs = [
        {
          job_name = "journal";
          journal = {
            max_age = "12h";
            labels = {
              job = "systemd-journal";
              host = "andromeda";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__hostname" ];
              target_label = "hostname";
            }
            {
              source_labels = [ "__journal_priority_keyword" ];
              target_label = "level";
            }
          ];
        }
        {
          job_name = "auth";
          static_configs = [{
            targets = [ "localhost" ];
            labels = {
              job = "auth";
              host = "andromeda";
              __path__ = "/var/log/auth.log";
            };
          }];
        }
      ];
    };
  };

# -----------------------------------------------------------------------------



  # Set your time zone.
  # time.timeZone = "Europe/Amsterdam";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  # services.xserver.enable = true;


  

  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # services.pulseaudio.enable = true;
  # OR
  # services.pipewire = {
  #   enable = true;
  #   pulse.enable = true;
  # };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  # users.users.alice = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
  #   packages = with pkgs; [
  #     tree
  #   ];
  # };

  # programs.firefox.enable = true;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  # environment.systemPackages = with pkgs; [
  #   vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  #   wget
  # ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
   networking.firewall.allowedTCPPorts = [ 22 80 443 3000 9090 9100 ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.11"; # Did you read the comment?

}

