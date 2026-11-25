# hardware-configuration.nix
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # 补充 nvme 控制器与 btrfs 文件系统驱动，确保 initrd 能识别 nvme0n1p3
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "mptspi"
    "uhci_hcd"
    "ehci_pci"
    "ahci"
    "nvme"
    "sd_mod"
    "sr_mod"
    "btrfs"
  ];
  boot.initrd.kernelModules = [ "btrfs" ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # 开启 Btrfs 支持（确保 initrd 打包 btrfs.ko 及相关工具）
  boot.supportedFilesystems = [ "btrfs" "ext4" ];

  system.fsPackages = [ pkgs.open-vm-tools ];

  fileSystems."/mount/hgfs" = {
    device = ".host:/VMshare";
    fsType = "fuse./run/current-system/sw/bin/vmhgfs-fuse";
    options = [
      "umask=22"
      "uid=1000"
      "gid=100"
      "allow_other"
      "defaults"
      "auto_unmount"
      "nofail"
      "x-systemd.automount"
    ];
  };

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
