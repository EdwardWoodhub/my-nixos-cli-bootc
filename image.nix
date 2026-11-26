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

      # 补充 bootupd（提供 bootupctl），确保 bootc install 与 bootupctl 可用
      environment.systemPackages = with pkgs; [
        bootc
        bootupd
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
        wantedBy = [ "multi-user.target" "local-fs.target" ];
        after = [ "local-fs.target" "ostree-finalize-staged.service" ];
        before = [ "shutdown.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          [ -d /boot/loader/entries ] || exit 0
          mkdir -p /boot/grub
          TMP_CFG=$(mktemp /boot/grub/grub.cfg.XXXXXX)

          cat > "$TMP_CFG" << 'EOF'
          insmod part_gpt
          insmod part_msdos
          insmod ext2
          insmod fat
          insmod search_fs_label
          insmod search_fs_uuid
          set timeout=3
          search --no-floppy --label --set=root root
          EOF

          for entry in $(ls -1r /boot/loader/entries/*.conf 2>/dev/null || true); do
            [ -f "$entry" ] || continue
            TITLE=$(grep -m1 '^title ' "$entry" | sed 's/^title //')
            LINUX=$(grep -m1 '^linux ' "$entry" | sed 's/^linux //')
            INITRD=$(grep -m1 '^initrd ' "$entry" | sed 's/^initrd //')
            OPTIONS=$(grep -m1 '^options ' "$entry" | sed 's/^options //')
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

          mv "$TMP_CFG" /boot/grub/grub.cfg
          sync
        '';
      };
    };
  };

  toplevel = nixos.config.system.build.toplevel;
  kernel = nixos.config.boot.kernelPackages.kernel;
  initrd = nixos.config.system.build.initialRamdisk;
  kver = kernel.modDirVersion;

  # 2. 单独预构建内核与双模 bootupd 载荷（纯实体文件）
  bootcPayload = pkgs.runCommand "nixos-bootc-payload" {
    nativeBuildInputs = with pkgs; [ grub2 grub2_efi bootupd coreutils ];
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

    # UEFI BOOTX64.EFI（移除写死的 gpt3 分区号，改由内嵌 grub.cfg 动态搜索）
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

    # 生成 bootupd 所需的 updates.json 元数据清单，否则 bootupctl 会拒绝安装
    bootupctl backend generate-update-metadata $out

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
# 3. 打包为 41 层均衡分布的 bootc 镜像
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  created = "now";
  maxLayers = 41;

  # 仅将 toplevel 放入 contents，使 buildLayeredImage 按 Nix 依赖图切分 /nix/store
  contents = [ toplevel ];

  # 在最终镜像根目录直接完成 OSTree/bootc 目录重映射
  extraCommands = ''
    cp -a ${bootcPayload}/usr ./
    chmod -R u+w usr

    # [核心修复 1] 将 /nix 迁移到 /usr/nix，并保留空的 /nix/store 供 initrd 绑定挂载
    if [ -d nix ]; then
      mv nix usr/nix
    fi
    mkdir -p nix/store

    # [核心修复 2] 将 NixOS 生成的 /etc 实体化为 OSTree 标准的 /usr/etc，避免悬空软链接
    mkdir -p usr/etc
    if [ -e etc ] || [ -L etc ]; then
      cp -rL etc/. usr/etc/ 2>/dev/null || true
      rm -rf etc
    fi

    # [核心修复 3] 补全 sys 与 boot/efi 等 FHS 挂载点骨架
    mkdir -p usr/bin var var/tmp sysroot ostree boot boot/efi dev proc sys run tmp
    ln -s ${toplevel} usr/nixos-toplevel
    ln -sf ${pkgs.bootupd}/bin/bootupctl usr/bin/bootupctl
    rm -rf var/run
    ln -s /run var/run
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
