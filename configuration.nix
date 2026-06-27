# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

let
  sops-nix = builtins.fetchTarball {
    url = "https://github.com/Mic92/sops-nix/archive/master.tar.gz";
    # Pin the hash to avoid silent updates — get it by running:
    # nix-prefetch-url --unpack https://github.com/Mic92/sops-nix/archive/master.tar.gz
    sha256 = "1f0j45mxb2zv672icpfvi7vnz8l4ccgxlkg79jca8avg00lj9gz3";
  };

  # Self-signed cert so nginx can complete the TLS handshake on direct-IP HTTPS
  # connections and issue a 301 redirect to philippwieck.com.
  selfSignedCert = pkgs.runCommand "self-signed-cert" { buildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -keyout $out/key.pem -out $out/cert.pem \
      -days 3650 -nodes -subj "/CN=localhost"
  '';
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
    sensors
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
    listenAddress = "127.0.0.1";
    exporters.node = {
      enable = true;
      port = 9100;
      listenAddress = "127.0.0.1";
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
      http_addr = "127.0.0.1";
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
    settings.PasswordAuthentication = false;
    # TODO: SECURITY — create a non-root wheel/sudo user with an SSH key, verify
    # you can log in and sudo, THEN change this to "no" (or "prohibit-password").
    # Direct root SSH on a public host is a major attack surface.
    settings.PermitRootLogin = "yes";
  };

  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "04:00";
    randomizedDelaySec = "30min";
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
    package = pkgs.docker_29;
    autoPrune.enable = true;
    # Default published container ports (-p) to loopback so they don't bypass
    # the NixOS firewall and land on the public interface. Use -p 127.0.0.1:X:Y
    # is then the default behaviour; expose deliberately via a reverse proxy.
    daemon.settings.ip = "127.0.0.1";
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@philippwieck.com";
  };

  # Public-facing web server — default landing page so the open 80/443 ports
  # (and the fail2ban nginx jails) reference a real, log-producing service.
  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedTlsSettings = true;

    # Define rate-limit zones in the http{} context.
    # "binary_remote_addr" uses 4 bytes per IP (vs 7–15 for text) — more efficient.
    # 10m zone holds ~160 000 IPs; rate = sustained req/s per IP.
    commonHttpConfig = ''
      limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
      limit_req_status 429;  # return 429 Too Many Requests instead of default 503
    '';

    virtualHosts."_" = {
      default = true;
      addSSL = true;
      sslCertificate = "${selfSignedCert}/cert.pem";
      sslCertificateKey = "${selfSignedCert}/key.pem";
      locations."/" = {
        extraConfig = ''
          return 301 https://philippwieck.com$request_uri;
        '';
      };
    };

    virtualHosts."daem0n1337.ddns.net" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
        extraConfig = ''
          limit_req zone=general burst=20 nodelay;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };

    virtualHosts."philippwieck.com" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:5000";
        proxyWebsockets = true;
        extraConfig = ''
          limit_req zone=general burst=20 nodelay;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };

    virtualHosts."status.philippwieck.com" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:5001";
        proxyWebsockets = true;
        extraConfig = ''
          limit_req zone=general burst=20 nodelay;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };

    virtualHosts."argos.philippwieck.com" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:5002";
        proxyWebsockets = true;
        extraConfig = ''
          limit_req zone=general burst=20 nodelay;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };
  };
			
  services.logind.lidSwitch = "ignore";

  # Allows pre-built binaries (e.g. VS Code Remote's bundled node) to run on
  # NixOS by shimming the missing /lib64/ld-linux-x86-64.so.2 interpreter path.
  programs.nix-ld.enable = true;
# -----------------------------------------------------------------------------
# kernel hardening

  boot.kernel.sysctl = {
    "net.ipv4.tcp_syncookies" = 1;     # SYN flood protection
    "net.ipv4.conf.all.rp_filter" = 1; # anti-spoofing (drop packets with impossible source routes)
    "kernel.dmesg_restrict" = 1;       # hide dmesg from non-root
    "kernel.kptr_restrict" = 2;        # hide kernel pointers from /proc
  };

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
        # "aggressive" also catches pubkey-only probes / preauth disconnects,
        # which "normal" mode misses when PasswordAuthentication is off.
        mode = "aggressive";
        maxretry = 3;
        findtime = "10m";
        bantime = "4h";
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
      # Catches port-22 probes that never reach auth: HTTP GETs at sshd,
      # malformed banners, invalid protocol identifiers. The stock sshd
      # filter only matches Failed-password/Invalid-user, so these slip
      # past it. Two strikes is plenty — legitimate clients never trip
      # this.
      sshd-preauth.settings = {
        enabled = true;
        port = "ssh";
        filter = "sshd-preauth";
        backend = "systemd";
        maxretry = 2;
        findtime = "10m";
        bantime = "24h";
      };
    };
  };

  # Custom filter file for sshd-preauth jail above.
  environment.etc."fail2ban/filter.d/sshd-preauth.conf".text = ''
    [Definition]
    failregex = ^.*sshd.*: kex_exchange_identification: .* from <HOST>.*$
                ^.*sshd.*: banner exchange: Connection from <HOST> port \d+: invalid format.*$
                ^.*sshd.*: Bad protocol version identification .* from <HOST>.*$
                ^.*sshd.*: Connection (closed|reset) by <HOST> port \d+ \[preauth\]$
    ignoreregex =
    journalmatch = _SYSTEMD_UNIT=sshd.service
  '';

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
        retention_period = "720h"; # keep logs 30 days, then delete
      };
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        compaction_interval = "10m";
        retention_enabled = true;
        retention_delete_delay = "2h";
        delete_request_store = "filesystem"; # required by Loki 3.x when retention is on
      };
    };
  };

  sops.secrets.sun_password = {
    neededForUsers = true; # must be decrypted before user accounts are applied
  };

  users.users.sun = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ]; # wheel = sudo; docker = manage containers
    hashedPasswordFile = config.sops.secrets.sun_password.path;
  };

  # Allow wheel users to sudo without a password — remove this line if you'd
  # rather be prompted for the password each time.
  security.sudo.wheelNeedsPassword = false;

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
      ];
    };
  };

  # Alert on every successful SSH login via a Slack/Mattermost-compatible
  # webhook. For Discord, append "/slack" to the webhook URL.
  # Put the URL in secrets/secrets.yaml under key: ssh_alert_webhook
  sops.secrets.cloudflare_api_token = {};

  services.ddclient = {
    enable = true;
    protocol = "cloudflare";
    zone = "philippwieck.com";
    username = "token";
    passwordFile = config.sops.secrets.cloudflare_api_token.path;
    domains = [
      "philippwieck.com"
      "argos.philippwieck.com"
      "status.philippwieck.com"
    ];
    use = "web, web=https://ipv4.icanhazip.com/";
    interval = "5min";
    quiet = true;
  };

  sops.secrets.ssh_alert_webhook = {
    restartUnits = [ "ssh-login-notify.service" ];
  };

  systemd.services.ssh-login-notify = {
    description = "Alert on successful SSH logins";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
      ExecStart = pkgs.writeShellScript "ssh-login-notify" ''
        set -u
        webhook="$(cat /run/secrets/ssh_alert_webhook 2>/dev/null || true)"
        ${pkgs.systemd}/bin/journalctl -f -n0 -o cat -u sshd.service | while IFS= read -r line; do
          case "$line" in
            *"Accepted publickey for "*|*"Accepted password for "*|*"Accepted keyboard-interactive/pam for "*)
              user="$(printf '%s' "$line" | ${pkgs.gnused}/bin/sed -n 's/.*Accepted [^ ]* for \([^ ]*\) from \([0-9a-fA-F:.]*\) port.*/\1/p')"
              ip="$(printf '%s' "$line" | ${pkgs.gnused}/bin/sed -n 's/.*Accepted [^ ]* for \([^ ]*\) from \([0-9a-fA-F:.]*\) port.*/\2/p')"
              [ -z "$user" ] && user="?"
              [ -z "$ip" ] && ip="?"
              [ -z "$webhook" ] && continue
              payload="$(printf '{"text":"🔓 SSH login on andromeda: %s@%s"}' "$user" "$ip")"
              ${pkgs.curl}/bin/curl -s -m 10 -H 'Content-Type: application/json' -d "$payload" "$webhook" >/dev/null || true
              ;;
          esac
        done
      '';
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
   # 3000/9090/9100 deliberately NOT exposed — Grafana/Prometheus/node_exporter
   # bind to localhost; reach Grafana via SSH tunnel:
   #   ssh -L 3000:localhost:3000 root@192.168.2.185
   networking.firewall.allowedTCPPorts = [ 22 80 443 ];
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

