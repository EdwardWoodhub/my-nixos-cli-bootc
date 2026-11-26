{ config, pkgs, lib, ... }:

{
  imports = [
    ./configuration.nix
  ];

  # 1. 禁用传统引导器（交由 bootc/ostree 接管引导与内核 BLS 条目）
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = lib.mkForce false;

  # 2. 清空硬编码根分区与交换分区（bootc 运行时通过内核参数 root=UUID=... 动态挂载）
  fileSystems."/" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
    neededForBoot = false;
  };
  swapDevices = lib.mkForce [];

  # 3. 禁用 systemd-gpt-auto-generator，避免自动生成的 /efi 挂载单元与 /boot/efi 冲突
  boot.kernelParams = [ "systemd.gpt_auto=0" ];

  # 4. 彻底关闭本地 Nix 守护进程与数据库管理（本地无 nix store 状态维护）
  nix.enable = lib.mkForce false;

  # 5. 确保 VMware 虚拟显卡驱动在早期加载，避免图形管理器卡在控制台日志界面
  boot.initrd.kernelModules = [ "vmwgfx" ];
  services.xserver.videoDrivers = [ "vmware" "modesetting" ];

  # 6. 强制启用本地虚拟终端 tty2 与串口终端 ttyS0，确保任何情况下均可切入文本登录
  systemd.services."getty@tty2".enable = true;
  systemd.services."serial-getty@ttyS0".enable = true;

  # 7. 预创建 HGFS 挂载点与 AccountsService 目录，确保不可变只读根文件系统下零报错启动
  systemd.tmpfiles.rules = [
    "d /mount/hgfs 0755 root root -"
    "d /var/lib/AccountsService 0755 root root -"
    "d /var/lib/AccountsService/users 0700 root root -"
    "d /var/lib/AccountsService/icons 0775 root root -"
  ];

  # 8. 确保目标系统内置 bootc 和 ostree 工具以支持后续的 bootc upgrade / rollback
  environment.systemPackages = with pkgs; [
    bootc
    ostree
    util-linux
    e2fsprogs
    dosfstools
  ];

  # 9. 默认优先使用标准 FHS 路径，同时保留 NixOS 系统路径以便 systemd 与核心组件正常解析
  environment.variables = {
    PATH = lib.mkForce "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/current-system/sw/bin";
  };
}
