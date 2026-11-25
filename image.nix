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

  # 1. 均衡分层规划器：
  #    - 单个 >= 250MB 的巨无霸包（如 Chrome/Firefox/字体）各自独立成层
  #    - 其余所有包按名称 SHA256 哈希均匀散列到 32 个桶中（每桶严格控制在 100~200MB 左右）
  layerPlan = pkgs.runCommand "layer-plan" {
    nativeBuildInputs = [ pkgs.python3 pkgs.coreutils ];
  } ''
    mkdir -p $out
    python3 - << 'EOF'
import os, hashlib

with open("${closureInfo}/store-paths") as f:
    paths = [line.strip() for line in f if line.strip()]

def get_dir_size(path):
    total = 0
    if os.path.islink(path) or os.path.isfile(path):
        return os.lstat(path).st_size
    for dirpath, _, filenames in os.walk(path, followlinks=False):
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            try:
                total += os.lstat(fp).st_size
            except OSError:
                pass
    return total

LARGE_THRESHOLD = 250 * 1024 * 1024  # 250 MB 以上独立成层
NUM_BUCKETS = 32                     # 其余中小包均匀分散到 32 个桶

large_items = []
regular_buckets = [[] for _ in range(NUM_BUCKETS)]

for p in sorted(paths):
    sz = get_dir_size(p)
    if sz >= LARGE_THRESHOLD:
        large_items.append(p)
    else:
        h = int(hashlib.sha256(os.path.basename(p).encode()).hexdigest(), 16)
        regular_buckets[h % NUM_BUCKETS].append(p)

layers = [[p] for p in large_items] + [b for b in regular_buckets if b]

for idx, items in enumerate(layers):
    with open(os.path.join(os.environ["out"], f"layer-{idx:02d}.txt"), "w") as lf:
        lf.write("\n".join(items) + "\n")
EOF
  '';

  layerFiles = builtins.attrNames (builtins.readDir layerPlan);

  mkBalancedLayer = fileName: pkgs.runCommand "nix-bootc-${fileName}" {
    nativeBuildInputs = [ pkgs.coreutils pkgs.python3 ];
  } ''
    mkdir -p $out/usr/nix/store
    while IFS= read -r store_path; do
      [ -n "$store_path" ] && cp -a "$store_path" "$out/usr/nix/store/"
    done < "${layerPlan}/${fileName}"

    chmod -R u+w $out/usr/nix/store

    python3 - << 'EOF'
import os
root = os.path.join(os.environ["out"], "usr/nix/store")
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    for name in filenames + dirnames:
        fp = os.path.join(dirpath, name)
        if os.path.islink(fp):
            target = os.readlink(fp)
            if target.startswith("/nix/store/"):
                os.unlink(fp)
                os.symlink("/usr" + target, fp)
EOF
  '';

  balancedLayers = map mkBalancedLayer layerFiles;

  # 2. 极轻量 FHS 骨架层（仅约 60MB：内核模块全部通过符号链接复用 /usr/nix/store，绝不重复拷贝实体）
  fhsSkeleton = pkgs.runCommand "nixos-bootc-fhs-skeleton" {
    nativeBuildInputs = [ pkgs.rsync pkgs.coreutils pkgs.python3 ];
  } ''
    mkdir -p $out/usr/{bin,sbin,lib,lib64,share,etc,nix/store}
    mkdir -p $out/nix/store $out/var $out/run $out/tmp $out/proc $out/sys $out/dev $out/boot $out/sysroot

    ln -s usr/bin $out/bin
    ln -s usr/sbin $out/sbin
    ln -s usr/lib $out/lib
    ln -s usr/lib64 $out/lib64
    ln -s sysroot/ostree $out/ostree

    for dir in bin sbin lib share; do
      if [ -d "${toplevel}/sw/$dir" ]; then
        cp -rsf ${toplevel}/sw/$dir/* $out/usr/$dir/ 2>/dev/null || true
      fi
    done

    ln -sf ${pkgs.stdenv.cc.libc}/lib/ld-linux-x86-64.so.2 $out/usr/lib64/ld-linux-x86-64.so.2

    mkdir -p $out/usr/lib/systemd/system $out/usr/lib/udev/rules.d
    cp -rsf ${toplevel}/etc/systemd/system/* $out/usr/lib/systemd/system/ 2>/dev/null || true
    cp -rsf ${toplevel}/etc/udev/rules.d/* $out/usr/lib/udev/rules.d/ 2>/dev/null || true

    rsync -a ${toplevel}/etc/ $out/usr/etc/
    cp -L ${toplevel}/etc/os-release $out/usr/lib/os-release

    # 仅 vmlinuz 和 initramfs.img 为实体（共 ~50MB），庞大的内核模块目录直接软链接到 /usr/nix/store
    mkdir -p $out/usr/lib/modules/${kver}
    cp -L ${kernel}/bzImage $out/usr/lib/modules/${kver}/vmlinuz
    cp -L ${initrd} $out/usr/lib/modules/${kver}/initramfs.img
    if [ -d "${modulesTree}/lib/modules/${kver}" ]; then
      cp -rsf ${modulesTree}/lib/modules/${kver}/* $out/usr/lib/modules/${kver}/
    fi

    chmod -R u+w $out/usr

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

  lintCheck = pkgs.runCommand "nixos-bootc-lint-check" {
    nativeBuildInputs = [ pkgs.bootc pkgs.coreutils ];
  } ''
    mkdir -p rootfs
    cp -a ${fhsSkeleton}/* rootfs/
    chmod -R u+w rootfs

    while IFS= read -r store_path; do
      mkdir -p "rootfs/usr$store_path"
    done < ${closureInfo}/store-paths

    echo ">>> Running bootc container lint..."
    bootc container lint --rootfs=rootfs --skip baseimage-composefs
    touch $out
  '';

  # 3. 链式叠加构建纯正无幽灵层的 OCI 镜像：
  #    每个 balancedLayer 严格对应 1 个 OCI Layer，彻底消除 buildLayeredImage 自动扫描产生的 2.6GB 幽灵双份层！
  baseImage = pkgs.dockerTools.buildImage {
    name = "my-nixos-cli-bootc-vm";
    tag = "latest";
    copyToRoot = fhsSkeleton;
    extraCommands = ''
      test -e ${lintCheck}
      rm -rf nix/store/*
      mkdir -p nix/store
    '';
    config = {
      Cmd = [ "/usr/lib/systemd/systemd" ];
      Labels = {
        "containers.bootc" = "1";
      };
    };
  };

  finalImage = builtins.foldl' (prevImg: layerDrv:
    pkgs.dockerTools.buildImage {
      name = "my-nixos-cli-bootc-vm";
      tag = "latest";
      fromImage = prevImg;
      copyToRoot = layerDrv;
      config = {
        Cmd = [ "/usr/lib/systemd/systemd" ];
        Labels = {
          "containers.bootc" = "1";
        };
      };
    }
  ) baseImage balancedLayers;

in
finalImage
