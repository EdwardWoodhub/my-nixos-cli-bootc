{ config, pkgs, lib, ... }:

{
  imports = [
    ./configuration.nix
  ];

  # 1. 禁用传统引导器（交由 bootc/ostree 接管 GRUB 与内核 BLS 引导项）
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = lib.mkForce false;

  # 2. 清空硬编码根分区与交换分区（bootc 运行时通过内核参数 root=UUID=... 动态挂载）
  fileSystems."/" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
  };
  swapDevices = lib.mkForce [];

  # 3. 彻底关闭本地 Nix 守护进程与数据库管理（本地无 nix store 状态维护）
  nix.enable = lib.mkForce false;

  # 4. 确保目标系统内置 bootc 和 ostree 工具以支持后续的 bootc upgrade / rollback
  environment.systemPackages = with pkgs; [
    bootc
    ostree
    util-linux
    e2fsprogs
    dosfstools
  ];

  # 5. 默认优先使用标准 FHS 路径，同时保留 NixOS 系统路径以便 systemd 与核心组件正常解析
  environment.variables = {
    PATH = lib.mkForce "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/current-system/sw/bin";
  };
}
