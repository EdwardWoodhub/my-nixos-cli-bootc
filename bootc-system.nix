{ config, pkgs, lib, ... }:

{
  imports = [
    ./configuration.nix
  ];

  # 1. 禁用传统引导器（交由 bootc/ostree 接管引导与内核 BLS 条目）
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = lib.mkForce false;

  # 2. 配置根文件系统与 /sysroot（ostree admin / bootc 依赖 /sysroot/ostree/repo）
  fileSystems."/" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
    neededForBoot = false;
  };
  fileSystems."/sysroot" = lib.mkForce {
    device = "/dev/disk/by-label/root";
    fsType = "ext4";
    neededForBoot = false;
    options = [ "defaults" "nofail" ];
  };
  fileSystems."/mount/hgfs" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
    neededForBoot = false;
    options = [ "noauto" ];
  };
  swapDevices = lib.mkForce [];

  # 3. 显式配置双控制台输出并禁用 systemd-gpt-auto-generator，防止 /efi 冲突挂载
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" "systemd.gpt_auto=0" ];

  # 4. 彻底关闭本地 Nix 守护进程与数据库管理（本地无 nix store 状态维护）
  nix.enable = lib.mkForce false;

  # 5. 禁用在 ostree 只读根下易报错的冗余后台服务
  services.nscd.enable = lib.mkForce false;
  system.nssModules = lib.mkForce [];
  systemd.oomd.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  systemd.services."wpa_supplicant".enable = lib.mkForce false;
  services.logrotate.enable = lib.mkForce false;
  systemd.services."flatpak-repo".enable = lib.mkForce false;

  # 6. 配置 OpenSSH（使用默认 /etc/ssh 路径，并在生成密钥前确保目录存在）
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = lib.mkForce "yes";
  };
  systemd.services."sshd-keygen".preStart = lib.mkBefore ''
    mkdir -p /etc/ssh /var/empty
    chmod 0755 /etc/ssh
    chmod 0555 /var/empty
  '';

  # 7. 保留 XFCE 桌面软件包，默认以命令行 multi-user.target 启动（需桌面时执行 sudo systemctl start display-manager）
  systemd.defaultUnit = lib.mkForce "multi-user.target";
  systemd.services."display-manager".enable = lib.mkForce false;
  boot.initrd.kernelModules = [ "vmwgfx" ];
  services.xserver.videoDrivers = [ "vmware" "modesetting" ];

  # 8. 强制将 getty@tty1/tty2 与 serial-getty@ttyS0 挂载到 multi-user.target
  systemd.services."getty@tty1" = {
    enable = true;
    wantedBy = [ "multi-user.target" ];
  };
  systemd.services."getty@tty2" = {
    enable = true;
    wantedBy = [ "multi-user.target" ];
  };
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "multi-user.target" ];
    serviceConfig.TTYReset = "no";
  };

  # 9. 清空冲突的自动挂载单元，并预创建 /root、/var/empty、SSH 密钥目录与 AccountsService 目录
  systemd.automounts = lib.mkForce [];
  systemd.tmpfiles.rules = [
    "d /root 0700 root root -"
    "d /var/empty 0555 root root -"
    "d /etc/ssh 0755 root root -"
    "d /mount/hgfs 0755 root root -"
    "d /var/lib/AccountsService 0755 root root -"
    "d /var/lib/AccountsService/users 0700 root root -"
    "d /var/lib/AccountsService/icons 0775 root root -"
  ];

  # 10. 确保目标系统内置 bootc 和 ostree 工具以支持后续的 bootc upgrade / rollback
  environment.systemPackages = with pkgs; [
    bootc
    ostree
    util-linux
    e2fsprogs
    dosfstools
  ];

  # 11. 默认优先使用标准 FHS 路径，同时保留 NixOS 系统路径以便 systemd 与核心组件正常解析
  environment.variables = {
    PATH = lib.mkForce "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/current-system/sw/bin";
  };
}
