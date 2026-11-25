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

  # 4. Stage 1 (Initrd) 早期绑定挂载：确保 switch_root 切换根文件系统前 /nix/store 已就绪
  boot.initrd.postMountCommands = ''
    mkdir -p /mnt-root/nix/store
    mount --bind /mnt-root/usr/nix/store /mnt-root/nix/store
  '';

  # 5. Stage 2 (Systemd) 持久化只读绑定挂载：保证系统运行期间 /nix/store 严格只读且可用
  systemd.mounts = [
    {
      what = "/usr/nix/store";
      where = "/nix/store";
      type = "none";
      options = "bind,ro";
      wantedBy = [ "local-fs.target" ];
      before = [ "local-fs.target" "sysinit.target" ];
      unitConfig = {
        DefaultDependencies = false;
      };
    }
  ];

  # 6. 确保目标系统内置 bootc 和 ostree 工具以支持后续的 bootc upgrade / rollback
  environment.systemPackages = with pkgs; [
    bootc
    ostree
    util-linux
    e2fsprogs
    dosfstools
  ];

  # 7. 默认优先使用标准 FHS 路径
  environment.variables = {
    PATH = lib.mkForce "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
  };
}
