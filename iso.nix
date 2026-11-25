{ config, pkgs, lib, ... }:

{
  imports = [
    <nixpkgs/nixos/modules/installer/cd-dvd/installation-cd-base.nix>
    ./configuration.nix
  ];

  boot.loader.grub.enable = lib.mkForce false;
  virtualisation.vmware.guest.enable = lib.mkForce false;

  image.baseName = lib.mkForce "my-nixos-cli-bootc-vm";
  isoImage.isoBaseName = lib.mkForce "my-nixos-cli-bootc-vm";
  isoImage.volumeID = lib.mkForce "NIXOS_BOOTC";

  # 新增：开启串口输出，确保 CI 无头 QEMU 冒烟测试能实时捕获系统启动与登录日志
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];

  security.sudo.wheelNeedsPassword = false;

  services.displayManager.autoLogin = {
    enable = true;
    user = "nack";
  };

  virtualisation.podman.enable = true;
  environment.systemPackages = with pkgs; [
    bootc
    ostree
    podman
    skopeo
    parted
    gptfdisk
  ];
}
