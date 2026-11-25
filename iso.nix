{ config, pkgs, lib, ... }:

{
  imports = [
    # 1. 引入官方 LiveCD 核心与安装器模块
    <nixpkgs/nixos/modules/installer/cd-dvd/installation-cd-base.nix>

    # 2. 引入你现有的系统配置
    ./configuration.nix
  ];

  # 3. 禁用与 LiveCD 冲突的实体机引导与硬件设置
  boot.loader.grub.enable = lib.mkForce false;
  virtualisation.vmware.guest.enable = lib.mkForce false;

  # 4. 配置 LiveCD ISO 的镜像名称与标签
  image.baseName = lib.mkForce "my-nixos-xfce-vm";
  isoImage.isoBaseName = lib.mkForce "my-nixos-xfce-vm";
  isoImage.volumeID = lib.mkForce "NIXOS_X11";

  # 5. 允许免密码 sudo，方便在 Live 环境下执行 bootc install
  security.sudo.wheelNeedsPassword = false;

  # 6. 配置 Live 默认用户免密自动登录 XFCE 桌面
  services.displayManager.autoLogin = {
    enable = true;
    user = "nack";
  };

  # 7. 预装 bootc、podman 与磁盘工具，支持从 LiveCD 直接将云端 bootc 镜像刷入本地磁盘
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
