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

  # 4. Stage 1 (Systemd Initrd) 早期绑定挂载：
  # 在根文件系统 /sysroot 挂载完成后、执行 switch_root 之前，将 /sysroot/usr/nix/store 绑定到 /sysroot/nix/store
  boot.initrd.systemd.services.bind-nix-store = {
    description = "Bind mount /sysroot/usr/nix/store to /sysroot/nix/store in initrd";
    wantedBy = [ "initrd.target" ];
    after = [ "sysroot.mount" ];
    before = [ "initrd-root-fs.target" "initrd-switch-root.target" ];
    unitConfig = {
      DefaultDependencies = false;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "/bin/mkdir -p /sysroot/nix/store"
        "/bin/mount --bind -o ro /sysroot/usr/nix/store /sysroot/nix/store"
      ];
    };
  };

  # 5. Stage 2 (Systemd) 持久化只读绑定挂载：保证系统进入正常阶段后 /nix/store 持续可用
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
