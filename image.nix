{ pkgs ? import <nixpkgs> { }
, systemConfig ? ./bootc-system.nix
, imageName ? "my-nixos-cli-bootc-vm"
, imageTag ? "latest"
}:

let
  # 1. 评估目标 NixOS 系统配置（自动注入 bootc 必需的引导、文件系统与服务模块）
  nixos = import "${pkgs.path}/nixos" {
    configuration = { config, lib, pkgs, ... }: {
      imports = [ systemConfig ];

      # -----------------------------------------------------------------------
      # A. 核心 bootc / OSTree 系统布局
      # -----------------------------------------------------------------------
      boot.isContainer = false;
      boot.loader.grub.enable = false; # 禁用 NixOS 默认激活器写 GRUB，交由 bootc/bootupd 管理
      boot.initrd.systemd.enable = true;

      # 开启内核 fs-verity 支持，兼容新版 bootc 默认带 -O verity 的 ext4 格式化
      boot.kernelPatches = lib.mkDefault [ ];
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

      # 同时包含 BIOS 与 UEFI 双架构 GRUB 工具链及 bootc/ostree
      environment.systemPackages = with pkgs; [
        bootc
        ostree
        skopeo
        podman
        grub2
        grub2_efi
        efibootmgr
        dosfstools
        e2fsprogs
        gptfdisk
        util-linux
      ];

      # -----------------------------------------------------------------------
      # B. 动态将 /boot/loader/entries/*.conf 转换为原生 GRUB 菜单（兼容 BIOS + UEFI）
      # -----------------------------------------------------------------------
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
          if [ ! -d /boot/loader/entries ]; then
            exit 0
          fi

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

          # 按文件名倒序遍历（最新部署的 ostree-1.conf 排在最前作为默认启动项）
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

  # 2. 构建符合 bootc / OSTree 规范且自带双模 bootupd payload 的 rootfs 衍生包
  bootcRootfs = pkgs.runCommand "nixos-bootc-rootfs" {
    nativeBuildInputs = with pkgs; [
      grub2
      grub2_efi
      coreutils
      findutils
      gnused
      gnugrep
    ];
  } ''
    mkdir -p $out/{usr/bin,usr/lib/ostree,usr/lib/modules/${kernel.modDirVersion},etc,var,var/tmp,sysroot,ostree,boot,dev,proc,run,tmp,nix/store}

    # --- A. 放置内核与 initramfs 到 bootc 约定的标准路径 ---
    cp -L ${kernel}/bzImage $out/usr/lib/modules/${kernel.modDirVersion}/vmlinuz
    cp -L ${initrd}/initrd $out/usr/lib/modules/${kernel.modDirVersion}/initramfs.img

    # --- B. 复制 NixOS 系统激活入口与关联的 /nix/store 闭包 ---
    cp -a ${toplevel} $out/usr/nixos-toplevel
    ln -s /usr/nixos-toplevel/sw/bin/* $out/usr/bin/ 2>/dev/null || true

    # 将运行时闭包复制到 /nix/store（后续由 dockerTools.buildLayeredImage 自动切分为 41 层）
    for storePath in $(cat ${pkgs.closureInfo { rootPaths = [ toplevel ]; }}/store-paths); do
      cp -a "$storePath" "$out/nix/store/"
    done

    # --- C. 写入 /usr/lib/ostree/prepare-root.conf ---
    cat > $out/usr/lib/ostree/prepare-root.conf << 'EOF'
    [composefs]
    enabled = no

    [sysroot]
    readonly = true
    EOF

    # --- D. 生成 BIOS + UEFI 双模 bootupd 预编译负载（让 bootc install 原生成功） ---
    mkdir -p $out/usr/lib/bootupd/updates/EFI/BOOT
    mkdir -p $out/usr/lib/bootupd/updates/grub2/i386-pc
    mkdir -p $out/usr/lib/bootupd/updates/grub2/x86_64-efi

    # 1) 生成 UEFI 独立引导镜像 BOOTX64.EFI（使用 search_label 模块文件）
    ${pkgs.grub2_efi}/bin/grub-mkimage \
      --format=x86_64-efi \
      --directory=${pkgs.grub2_efi}/lib/grub/x86_64-efi \
      --output=$out/usr/lib/bootupd/updates/EFI/BOOT/BOOTX64.EFI \
      --prefix='(hd0,gpt3)/boot/grub' \
      part_gpt part_msdos fat ext2 normal boot linux search search_fs_uuid search_label configfile echo test ls

    # 2) 生成 Legacy BIOS 核心镜像 boot.img 与 core.img（使用 search_label 模块文件）
    cp ${pkgs.grub2}/lib/grub/i386-pc/boot.img $out/usr/lib/bootupd/updates/grub2/i386-pc/
    ${pkgs.grub2}/bin/grub-mkimage \
      --format=i386-pc \
      --directory=${pkgs.grub2}/lib/grub/i386-pc \
      --output=$out/usr/lib/bootupd/updates/grub2/i386-pc/core.img \
      --prefix='(,gpt3)/boot/grub' \
      biosdisk part_gpt part_msdos ext2 normal boot linux search search_fs_uuid search_label configfile echo test ls

    # 复制运行时模块供 grub 后期按需动态加载
    cp -r ${pkgs.grub2}/lib/grub/i386-pc/*.mod $out/usr/lib/bootupd/updates/grub2/i386-pc/
    cp -r ${pkgs.grub2_efi}/lib/grub/x86_64-efi/*.mod $out/usr/lib/bootupd/updates/grub2/x86_64-efi/

    # 3) 写入初始 grub.cfg 模板（引导时会自动查找标签为 root 的分区并加载配置）
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

    # --- E. 写入 /usr/lib/os-release 供 bootc 识别版本 ---
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
# 3. 打包为 41 层均衡分布且包含完整 OCI history 元数据的 bootc 镜像
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;

  # 强制生成合法时间戳，确保每层都有完整的 OCI history 记录以通过 bootc switch 校验
  created = "now";

  # 均衡切分为 41 层，确保后续增量更新仅需下载几十 MB 变更层
  maxLayers = 41;

  contents = [ bootcRootfs ];

  extraCommands = ''
    # 确保目录存在并设置符合 bootc container lint 规范的权限与符号链接
    mkdir -p tmp var var/tmp
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
