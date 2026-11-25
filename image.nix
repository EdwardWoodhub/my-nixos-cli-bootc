{ pkgs ? import <nixpkgs> {}
, configFile ? ./bootc-system.nix
}:

let
  nixos = import <nixpkgs/nixos> {
    configuration = configFile;
    system = "x86_64-linux";
  };

  toplevel = nixos.system;
  kernel = nixos.config.boot.kernelPackages.kernel;
  kver = kernel.modDirVersion;
  initrd = "${nixos.config.system.build.initialRamdisk}/initrd";
  modulesTree = nixos.config.system.modulesTree;

  closureInfo = pkgs.closureInfo {
    rootPaths = [ toplevel modulesTree ];
  };

  # 将 32 个 Nix Base32 字符分成 32 个独立的 OCI 层桶，每个桶约 100~200MB
  # 修改单个软件时，仅会触发对应哈希首字符那 1 个桶的重新下载
  base32Chars = [
    "0" "1" "2" "3" "4" "5" "6" "7" "8" "9"
    "a" "b" "c" "d" "f" "g" "h" "i" "j" "k"
    "l" "m" "n" "p" "q" "r" "s" "v" "w" "x" "y" "z"
  ];

  mkStoreBucket = prefix: pkgs.runCommand "nix-store-bucket-${prefix}" {
    nativeBuildInputs = [ pkgs.coreutils ];
  } ''
    mkdir -p $out/usr/nix/store
    while IFS= read -r store_path; do
      base_name=$(basename "$store_path")
      case "$base_name" in
        ${prefix}*)
          cp -a "$store_path" "$out/usr/nix/store/"
          ;;
      esac
    done < ${closureInfo}/store-paths
  '';

  storeBuckets = map mkStoreBucket base32Chars;

  # 构建 FHS 骨架、内核与 /usr/etc（不包含庞大的 store 实体，体积仅约 150MB）
  fhsSkeleton = pkgs.runCommand "nixos-bootc-fhs-skeleton" {
    nativeBuildInputs = [ pkgs.rsync pkgs.coreutils pkgs.python3 ];
  } ''
    mkdir -p $out/usr/{bin,sbin,lib,lib64,share,etc,nix/store}
    mkdir -p $out/nix/store $out/var $out/run $out/tmp $out/proc $out/sys $out/dev $out/boot $out/sysroot

    # 1. 创建标准的 UsrMerge 与 OSTree 顶层符号链接
    ln -s usr/bin $out/bin
    ln -s usr/sbin $out/sbin
    ln -s usr/lib $out/lib
    ln -s usr/lib64 $out/lib64
    ln -s sysroot/ostree $out/ostree

    # 2. 暴露标准的 FHS 接口
    for dir in bin sbin lib share; do
      if [ -d "${toplevel}/sw/$dir" ]; then
        cp -rsf ${toplevel}/sw/$dir/* $out/usr/$dir/ 2>/dev/null || true
      fi
    done

    # 3. 提供标准 FHS 动态链接器
    ln -sf ${pkgs.stdenv.cc.libc}/lib/ld-linux-x86-64.so.2 $out/usr/lib64/ld-linux-x86-64.so.2

    # 4. 暴露 systemd 单元与 udev 规则到标准 /usr/lib 路径
    mkdir -p $out/usr/lib/systemd/system $out/usr/lib/udev/rules.d
    cp -rsf ${toplevel}/etc/systemd/system/* $out/usr/lib/systemd/system/ 2>/dev/null || true
    cp -rsf ${toplevel}/etc/udev/rules.d/* $out/usr/lib/udev/rules.d/ 2>/dev/null || true

    # 5. 生成 OSTree 规范的 /usr/etc
    rsync -a ${toplevel}/etc/ $out/usr/etc/
    cp -L ${toplevel}/etc/os-release $out/usr/lib/os-release

    # 6. 按照 bootc 规范放置内核、initramfs 与聚合后的内核模块
    mkdir -p $out/usr/lib/modules/${kver}
    cp -L ${kernel}/bzImage $out/usr/lib/modules/${kver}/vmlinuz
    cp -L ${initrd} $out/usr/lib/modules/${kver}/initramfs.img
    if [ -d "${modulesTree}/lib/modules/${kver}" ]; then
      rsync -aL ${modulesTree}/lib/modules/${kver}/ $out/usr/lib/modules/${kver}/
    fi

    chmod -R u+w $out/usr

    # 7. 重写符号链接，重定向至 /usr 下的实际目标
    python3 - << 'EOF'
import os

out_dir = os.path.abspath(os.environ["out"])

for dirpath, dirnames, filenames in os.walk(out_dir, followlinks=False):
    for name in filenames + dirnames:
        full_path = os.path.join(dirpath, name)
        if not os.path.islink(full_path):
            continue
        target = os.readlink(full_path)

        if target.startswith("/nix/store/"):
            os.unlink(full_path)
            os.symlink("/usr" + target, full_path)
        elif target.startswith("/etc/static/"):
            os.unlink(full_path)
            os.symlink("/usr" + target, full_path)
        elif dirpath.startswith(os.path.join(out_dir, "usr/etc")) and target.startswith("/etc/"):
            os.unlink(full_path)
            os.symlink("/usr" + target, full_path)
EOF
  '';

  # 合并检查的完整视图（仅用于构建期执行 bootc container lint，不打入最终单层）
  lintView = pkgs.symlinkJoin {
    name = "nixos-bootc-lint-view";
    paths = [ fhsSkeleton ] ++ storeBuckets;
  };

in
pkgs.dockerTools.buildLayeredImage {
  name = "my-nixos-cli-bootc-vm";
  tag = "latest";

  maxLayers = 100;

  # 将 32 个独立的 store 桶 + FHS 骨架作为独立派生传入，实现真正均衡的层级切分
  contents = storeBuckets ++ [ fhsSkeleton ];

  # 在镜像封装阶段直接对合并后的根目录执行 bootc lint 检查，并确保顶层 /nix/store 为空
  extraCommands = ''
    ${pkgs.bootc}/bin/bootc container lint --rootfs=. --skip baseimage-composefs
    rm -rf nix/store/*
    mkdir -p nix/store
  '';

  config = {
    Cmd = [ "/usr/lib/systemd/systemd" ];
    Labels = {
      "containers.bootc" = "1";
    };
  };
}
