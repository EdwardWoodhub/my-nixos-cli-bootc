{ pkgs ? import <nixpkgs> { }
, systemConfig ? ./bootc-system.nix
, imageName ? "my-nixos-cli-bootc-vm"
, imageTag ? "latest"
}:

let
  # 1. 评估目标 NixOS 系统配置
  nixos = import "${pkgs.path}/nixos" {
    configuration = { config, lib, pkgs, ... }: {
      imports = [ systemConfig ];

      boot.isContainer = false;
      boot.loader.grub.enable = false;
      boot.initrd.systemd.enable = true;

      # 将 ostree-prepare-root 注入 initrd，在 find-nixos-closure 之前把 /sysroot 切换到当前 OSTree 部署目录
      boot.initrd.systemd.extraBin."ostree-prepare-root" = "${pkgs.ostree}/lib/ostree/ostree-prepare-root";
      boot.initrd.systemd.contents."/etc/ostree/prepare-root.conf".text = ''
        [composefs]
        enabled = no

        [sysroot]
        readonly = true
      '';

      boot.initrd.systemd.services.ostree-prepare-root = {
        description = "OSTree Prepare Root";
        wantedBy = [ "initrd-root-fs.target" ];
        after = [ "sysroot.mount" ];
        before = [ "initrd-root-fs.target" "initrd-find-nixos-closure.service" "initrd-parse-etc.service" ];
        unitConfig = {
          DefaultDependencies = false;
          ConditionKernelCommandLine = "ostree";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "/bin/ostree-prepare-root /sysroot";
        };
      };

      # 确保 NixOS initrd 在 ostree-prepare-root 切换完 /sysroot 之后再查找闭包
      boot.initrd.systemd.services.initrd-find-nixos-closure = {
        after = [ "ostree-prepare-root.service" ];
        requires = [ "ostree-prepare-root.service" ];
      };

      boot.initrd.availableKernelModules = [
        "nvme" "xhci_pci" "ahci" "usbhid" "sd_mod" "sr_mod"
        "vmw_pvscsi" "vmw_vmci" "vmwgfx" "e1000" "e1000e" "vmxnet3"
        "ext4" "vfat" "nls_cp437" "nls_iso8859-1" "overlay"
      ];

      # 预置 prepare-root.conf（关闭 composefs 避免自定义 initrd 挂载失败）
      environment.etc."ostree/prepare-root.conf".text = ''
        [composefs]
        enabled = no

        [sysroot]
        readonly = true
      '';

      # 包含 BIOS 与 UEFI 双架构 GRUB 工具链及 bootc/ostree
      environment.systemPackages = with pkgs; [
        bootc
        ostree
        grub2
        grub2_efi
        efibootmgr
        dosfstools
        e2fsprogs
        gptfdisk
        util-linux
      ];

      # 动态将 /boot/loader/entries/*.conf 转换为原生 GRUB 菜单（兼容 BIOS + UEFI）
      systemd.services.update-grub-bls = {
        description = "Generate GRUB menuentries from OSTree BLS entries";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "ostree-finalize-staged.service" ];
        before = [ "shutdown.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "update-grub-bls" ''
            set -euo pipefail
            [ -d /boot/loader/entries ] || exit 0
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
          '';
        };
      };
    };
  };

  toplevel = nixos.config.system.build.toplevel;
  kernel = nixos.config.boot.kernelPackages.kernel;
  initrd = nixos.config.system.build.initialRamdisk;
  kver = kernel.modDirVersion;

  # 从 NixOS 评估配置中全量导出所有声明的用户与用户组（含系统服务账号）
  allUsers = nixos.config.users.users;
  allGroups = nixos.config.users.groups;

  passwdLines = pkgs.lib.mapAttrsToList (name: u:
    let
      uid = toString (if u.uid != null then u.uid else 999);
      gid = toString (
        if u.group != null && builtins.hasAttr u.group allGroups && allGroups.${u.group}.gid != null
        then allGroups.${u.group}.gid
        else (if name == "root" then 0 else 100)
      );
      desc = if u.description != null then u.description else name;
      home = if u.home != null then u.home else "/var/empty";
      shell =
        if (name == "root" || name == "nack")
        then "/run/current-system/sw/bin/bash"
        else "/run/current-system/sw/bin/nologin";
    in "${name}:x:${uid}:${gid}:${desc}:${home}:${shell}"
  ) (pkgs.lib.filterAttrs (_: u: u.uid != null) allUsers);

  groupLines = pkgs.lib.mapAttrsToList (name: g:
    let
      gid = toString g.gid;
      members = pkgs.lib.concatStringsSep "," (g.members or []);
    in "${name}:x:${gid}:${members}"
  ) (pkgs.lib.filterAttrs (_: g: g.gid != null) allGroups);

  shadowLines = pkgs.lib.mapAttrsToList (name: _:
    "${name}:!:19000:0:99999:7:::"
  ) (pkgs.lib.filterAttrs (_: u: u.uid != null) allUsers);

  generatedPasswd = pkgs.writeText "nixos-bootc-passwd" (pkgs.lib.concatStringsSep "\n" passwdLines + "\n");
  generatedGroup = pkgs.writeText "nixos-bootc-group" (pkgs.lib.concatStringsSep "\n" groupLines + "\n");
  generatedShadow = pkgs.writeText "nixos-bootc-shadow" (pkgs.lib.concatStringsSep "\n" shadowLines + "\n");

  # 2. 单独预构建内核与双模 bootupd 载荷（纯实体文件）
  bootcPayload = pkgs.runCommand "nixos-bootc-payload" {
    nativeBuildInputs = with pkgs; [ grub2 grub2_efi coreutils ];
  } ''
    mkdir -p $out/usr/lib/ostree
    mkdir -p $out/usr/lib/modules/${kver}
    mkdir -p $out/usr/lib/bootupd/updates/EFI/BOOT
    mkdir -p $out/usr/lib/bootupd/updates/grub2/i386-pc
    mkdir -p $out/usr/lib/bootupd/updates/grub2/x86_64-efi

    # 实体内核与 initramfs（确保 ostree deploy 必然扫描命中）
    cp -L ${kernel}/bzImage $out/usr/lib/modules/${kver}/vmlinuz
    cp -L ${initrd}/initrd $out/usr/lib/modules/${kver}/initramfs.img
    chmod 0644 $out/usr/lib/modules/${kver}/{vmlinuz,initramfs.img}

    # prepare-root.conf
    cat > $out/usr/lib/ostree/prepare-root.conf << 'EOF'
    [composefs]
    enabled = no

    [sysroot]
    readonly = true
    EOF

    # UEFI BOOTX64.EFI
    ${pkgs.grub2_efi}/bin/grub-mkimage \
      --format=x86_64-efi \
      --directory=${pkgs.grub2_efi}/lib/grub/x86_64-efi \
      --output=$out/usr/lib/bootupd/updates/EFI/BOOT/BOOTX64.EFI \
      --prefix='/boot/grub' \
      part_gpt part_msdos fat ext2 normal boot linux search search_fs_uuid search_label configfile echo test ls

    # Legacy BIOS boot.img 与 core.img
    cp ${pkgs.grub2}/lib/grub/i386-pc/boot.img $out/usr/lib/bootupd/updates/grub2/i386-pc/
    ${pkgs.grub2}/bin/grub-mkimage \
      --format=i386-pc \
      --directory=${pkgs.grub2}/lib/grub/i386-pc \
      --output=$out/usr/lib/bootupd/updates/grub2/i386-pc/core.img \
      --prefix='/boot/grub' \
      biosdisk part_gpt part_msdos ext2 normal boot linux search search_fs_uuid search_label configfile echo test ls

    cp -r ${pkgs.grub2}/lib/grub/i386-pc/*.mod $out/usr/lib/bootupd/updates/grub2/i386-pc/
    cp -r ${pkgs.grub2_efi}/lib/grub/x86_64-efi/*.mod $out/usr/lib/bootupd/updates/grub2/x86_64-efi/

    cat > $out/usr/lib/bootupd/updates/grub2/grub.cfg << 'EOF'
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    insmod fat
    insmod search_fs_label
    set timeout=3
    search --no-floppy --label --set=root root
    if [ -f /boot/grub/grub.cfg ]; then
      configfile /boot/grub/grub.cfg
    fi
    EOF

    cat > $out/usr/lib/os-release << 'EOF'
    NAME="NixOS"
    ID=nixos
    VERSION="26.05 (Yarara)"
    VERSION_ID="26.05"
    PRETTY_NAME="NixOS 26.05 (Yarara) bootc"
    OSTREE_VERSION="26.05"
    EOF
  '';

in
# 3. 打包为 100 层均衡分布的 bootc 镜像
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  created = "now";
  maxLayers = 100;

  contents = [
    pkgs.glibc
    pkgs.systemd
    kernel
    toplevel
  ] ++ pkgs.lib.optionals (nixos.config.hardware.enableRedistributableFirmware or false) [
    pkgs.linux-firmware
  ];

  # 构建标准 OSTree/bootc 目录拓扑并写入全量 NixOS 系统账号
  extraCommands = ''
    cp -a ${bootcPayload}/usr ./
    chmod -R u+w usr

    # 1. 保留软链接原样拷贝 ${toplevel}/etc 到 /usr/etc，并清除顶层 /etc
    mkdir -p usr/etc
    cp -a ${toplevel}/etc/. usr/etc/
    chmod -R u+w usr/etc
    rm -rf etc

    # 2. 写入全量 NixOS 系统账号数据库（passwd / group / shadow）并固化 root 与 nack 密码哈希
    cp ${generatedPasswd} usr/etc/passwd
    cp ${generatedGroup} usr/etc/group
    cp ${generatedShadow} usr/etc/shadow
    ROOT_HASH=$(${pkgs.mkpasswd}/bin/mkpasswd -m sha-512 root)
    NACK_HASH=$(${pkgs.mkpasswd}/bin/mkpasswd -m sha-512 nack)
    chmod 0644 usr/etc/passwd usr/etc/group
    chmod 0640 usr/etc/shadow
    sed -i "s|^root:[^:]*:|root:''${ROOT_HASH}:|" usr/etc/shadow
    sed -i "s|^nack:[^:]*:|nack:''${NACK_HASH}:|" usr/etc/shadow

    # 3. 构建标准 OSTree/bootc FHS 软链接拓扑（补齐 /bin/sh，确保标准 POSIX/systemd 脚本直接可执行）
    mkdir -p bin usr/bin var var/tmp sysroot boot boot/efi dev proc sys run tmp
    rm -rf home root opt srv mnt ostree usr/local var/run
    ln -s var/home home
    ln -s var/roothome root
    ln -s var/opt opt
    ln -s var/srv srv
    ln -s var/mnt mnt
    ln -s sysroot/ostree ostree
    ln -s ../var/usrlocal usr/local
    ln -s /run var/run
    ln -s ${toplevel} usr/nixos-toplevel
    ln -s /run/current-system/sw/bin/sh bin/sh
    ln -s /run/current-system/sw/bin/login usr/bin/login
    ln -s /run/current-system/sw/bin/sh usr/bin/sh
    chmod 1777 tmp var/tmp
  '';

  config = {
    Cmd = [ "/usr/nixos-toplevel/init" ];
    Labels = {
      "containers.bootc" = "1";
      "ostree.bootable" = "true";
    };
  };
}
