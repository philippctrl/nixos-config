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
  ];

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets.wifi_passphrase = {
      restartUnits = [ "wpa_supplicant-wlp0s20f3.service" ];
    };
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


  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false; # TODO deactivate
    settings.PermitRootLogin = "yes";
  };




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
   networking.firewall.allowedTCPPorts = [ 22 80 443 ];
   networking.firewall.allowedUDPPorts = [ 67 68 ];
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

