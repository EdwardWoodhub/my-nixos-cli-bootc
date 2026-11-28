{ config, pkgs, lib, ... }:

{
  imports = [
    ./configuration.nix
  ];

  # 1. 禁用传统引导器（交由 bootc/ostree 接管引导与内核 BLS 条目）
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = lib.mkForce false;

  # 2. 清空硬编码根分区（/sysroot 与 /boot 的 bind-mount 由部署 fstab 接管，避免 initrd-fstab 重复生成 sysroot.mount）
  fileSystems."/" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
    neededForBoot = false;
  };
  fileSystems."/mount/hgfs" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
    neededForBoot = false;
    options = [ "noauto" ];
  };
  swapDevices = lib.mkForce [];

  # 3. 显式配置双控制台输出，并禁用 systemd-gpt-auto-generator 与 systemd-ssh-generator
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200"
    "systemd.gpt_auto=0"
    "systemd.ssh_auto=no"
  ];

  # 4. 彻底关闭本地 Nix 守护进程与数据库管理（本地无 nix store 状态维护）
  nix.enable = lib.mkForce false;

  # 5. 禁用在 ostree 只读根下易报错的冗余后台服务（NixOS 断言要求关闭 nscd 时必须同时清空 nssModules）
  services.nscd.enable = lib.mkForce false;
  system.nssModules = lib.mkForce [];
  systemd.oomd.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  systemd.services."wpa_supplicant".enable = lib.mkForce false;
  services.logrotate.enable = lib.mkForce false;
  systemd.services."flatpak-repo".enable = lib.mkForce false;

  # 6. 配置常驻 OpenSSH 守护进程（不触碰 chattr +i 锁定的 /var/empty，仅操作 /run/ssh）
  services.openssh = {
    enable = true;
    startWhenNeeded = false;
    settings = {
      PermitRootLogin = lib.mkForce "yes";
      PasswordAuthentication = lib.mkForce true;
      UsePAM = lib.mkForce true;
    };
  };
  systemd.services."sshd-keygen".enable = lib.mkForce false;

  systemd.services."bootc-sshd-setup" = {
    description = "Generate SSH host keys and runtime config in /run/ssh";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "bootc-sshd-setup" ''
        set -euo pipefail
        ${pkgs.coreutils}/bin/mkdir -p /run/ssh
        ${pkgs.coreutils}/bin/chmod 0700 /run/ssh
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f /run/ssh/ssh_host_ed25519_key -N "" -q
        ${pkgs.openssh}/bin/ssh-keygen -t rsa -b 2048 -f /run/ssh/ssh_host_rsa_key -N "" -q
        ${pkgs.coreutils}/bin/printf '%s\n' \
          'Port 22' \
          'HostKey /run/ssh/ssh_host_ed25519_key' \
          'HostKey /run/ssh/ssh_host_rsa_key' \
          'PermitRootLogin yes' \
          'PasswordAuthentication yes' \
          'UsePAM yes' \
          'PidFile /run/sshd.pid' \
          'Subsystem sftp ${pkgs.openssh}/libexec/sftp-server' \
          > /run/ssh/sshd_config
      ''}";
    };
  };

  systemd.services."sshd" = {
    enable = true;
    wantedBy = [ "multi-user.target" ];
    after = [ "bootc-sshd-setup.service" "network.target" ];
    requires = [ "bootc-sshd-setup.service" ];
    serviceConfig = {
      ExecStartPre = lib.mkForce "${pkgs.openssh}/bin/sshd -t -f /run/ssh/sshd_config";
      ExecStart = lib.mkForce "${pkgs.openssh}/bin/sshd -D -e -f /run/ssh/sshd_config";
    };
  };

  # 7. 绑定 /boot 并重新挂载为可写（解除 sysroot readonly 继承），再同步 OSTree BLS 条目到 GRUB 配置
  systemd.services."ostree-boot-link" = {
    description = "Bind-mount /sysroot/boot to /boot as rw for ostree/bootc";
    unitConfig.DefaultDependencies = false;
    wantedBy = [ "local-fs.target" ];
    before = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "ostree-boot-link" ''
        ${pkgs.coreutils}/bin/mkdir -p /boot
        if [ -d /sysroot/boot/loader ] && ! ${pkgs.util-linux}/bin/mountpoint -q /boot; then
          ${pkgs.util-linux}/bin/mount --bind /sysroot/boot /boot
        fi
        if ${pkgs.util-linux}/bin/mountpoint -q /boot; then
          ${pkgs.util-linux}/bin/mount -o remount,rw /boot || true
        fi
        if ${pkgs.util-linux}/bin/mountpoint -q /sysroot/boot/efi && ! ${pkgs.util-linux}/bin/mountpoint -q /boot/efi; then
          ${pkgs.util-linux}/bin/mount --bind /sysroot/boot/efi /boot/efi
        fi
      ''}";
    };
  };

  systemd.services."update-grub-bls" = {
    description = "Generate GRUB menuentries from OSTree BLS entries";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "ostree-boot-link.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "update-grub-bls" ''
        set -euo pipefail
        [ -d /boot/loader/entries ] || exit 0
        ${pkgs.util-linux}/bin/mount -o remount,rw /boot 2>/dev/null || true
        ${pkgs.coreutils}/bin/mkdir -p /boot/grub
        TMP_CFG=$(${pkgs.coreutils}/bin/mktemp /boot/grub/grub.cfg.XXXXXX)

        ${pkgs.coreutils}/bin/cat > "$TMP_CFG" << 'EOF'
        insmod part_gpt
        insmod part_msdos
        insmod ext2
        insmod fat
        insmod search_fs_label
        insmod search_fs_uuid
        set timeout=3
        search --no-floppy --label --set=root root
        EOF

        for entry in $(${pkgs.coreutils}/bin/ls -1r /boot/loader/entries/*.conf 2>/dev/null || true); do
          [ -f "$entry" ] || continue
          TITLE=$(${pkgs.gnugrep}/bin/grep -m1 '^title ' "$entry" | ${pkgs.gnused}/bin/sed 's/^title //')
          LINUX=$(${pkgs.gnugrep}/bin/grep -m1 '^linux ' "$entry" | ${pkgs.gnused}/bin/sed 's/^linux //')
          INITRD=$(${pkgs.gnugrep}/bin/grep -m1 '^initrd ' "$entry" | ${pkgs.gnused}/bin/sed 's/^initrd //')
          OPTIONS=$(${pkgs.gnugrep}/bin/grep -m1 '^options ' "$entry" | ${pkgs.gnused}/bin/sed 's/^options //')
          if [ -n "$LINUX" ] && [ -n "$OPTIONS" ]; then
            {
              echo ""
              echo "menuentry \"$TITLE\" {"
              echo "  linux $LINUX $OPTIONS"
              [ -n "$INITRD" ] && echo "  initrd $INITRD"
              echo "}"
            } >> "$TMP_CFG"
          fi
        done

        ${pkgs.coreutils}/bin/mv "$TMP_CFG" /boot/grub/grub.cfg
        ${pkgs.coreutils}/bin/sync
      ''}";
    };
  };

  # 8. 保留 XFCE 桌面软件包，默认以命令行 multi-user.target 启动（需桌面时执行 sudo systemctl start display-manager）
  systemd.defaultUnit = lib.mkForce "multi-user.target";
  systemd.services."display-manager".enable = lib.mkForce false;
  boot.initrd.kernelModules = [ "vmwgfx" ];
  services.xserver.videoDrivers = [ "vmware" "modesetting" ];

  # 9. 强制将 getty@tty1/tty2 与 serial-getty@ttyS0 挂载到 multi-user.target
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

  # 10. 初始化标准 OSTree /var/* 持久化目录（对应 /home、/root、/opt、/srv、/mnt、/usr/local 软链接）
  systemd.automounts = lib.mkForce [];
  systemd.tmpfiles.rules = [
    "d /var/home 0755 root root -"
    "d /var/home/nack 0700 nack users -"
    "d /var/roothome 0700 root root -"
    "d /var/opt 0755 root root -"
    "d /var/srv 0755 root root -"
    "d /var/mnt 0755 root root -"
    "d /var/mnt/hgfs 0755 root root -"
    "d /var/usrlocal 0755 root root -"
    "d /var/empty 0555 root root -"
    "d /mount/hgfs 0755 root root -"
    "d /var/lib/AccountsService 0755 root root -"
    "d /var/lib/AccountsService/users 0700 root root -"
    "d /var/lib/AccountsService/icons 0775 root root -"
  ];

  # 11. 确保目标系统内置 bootc 和 ostree 工具以支持后续的 bootc upgrade / rollback
  environment.systemPackages = with pkgs; [
    bootc
    ostree
    util-linux
    e2fsprogs
    dosfstools
  ];

  # 12. 默认优先使用标准 FHS 路径，同时保留 NixOS 系统路径以便 systemd 与核心组件正常解析
  environment.variables = {
    PATH = lib.mkForce "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/current-system/sw/bin";
  };
}
