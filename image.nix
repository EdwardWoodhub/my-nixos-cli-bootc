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

  # 1. 构建极轻量 FHS 骨架（仅 ~60MB）
  fhsSkeleton = pkgs.runCommand "nixos-bootc-fhs-skeleton" {
    nativeBuildInputs = [ pkgs.rsync pkgs.coreutils pkgs.python3 pkgs.bootc ];
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

    # 直接在临时拷贝上做 lint 校验
    mkdir -p /tmp/lint-rootfs
    cp -a $out/* /tmp/lint-rootfs/
    while IFS= read -r store_path; do
      mkdir -p "/tmp/lint-rootfs/usr$store_path"
    done < ${closureInfo}/store-paths
    bootc container lint --rootfs=/tmp/lint-rootfs --skip baseimage-composefs
    rm -rf /tmp/lint-rootfs
  '';

in
# 2. 单步多核并行直接生成标准 Docker/OCI Archive（零中间拷贝、零链式滚雪球、速度极快）
pkgs.runCommand "my-nixos-cli-bootc-vm.tar" {
  nativeBuildInputs = [ pkgs.python3 pkgs.coreutils ];
} ''
  python3 - << 'EOF'
import os, json, hashlib, tarfile, time
from concurrent.futures import ThreadPoolExecutor

out_tar = os.environ["out"]
skeleton_dir = "${fhsSkeleton}"
with open("${closureInfo}/store-paths") as f:
    store_paths = sorted([line.strip() for line in f if line.strip()])

def get_dir_size(path):
    total = 0
    if os.path.islink(path) or os.path.isfile(path):
        return os.lstat(path).st_size
    for dirpath, _, filenames in os.walk(path, followlinks=False):
        for fn in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, fn)).st_size
            except OSError:
                pass
    return total

LARGE_THRESHOLD = 250 * 1024 * 1024
NUM_BUCKETS = 32

large_items = []
regular_buckets = [[] for _ in range(NUM_BUCKETS)]

for p in store_paths:
    if get_dir_size(p) >= LARGE_THRESHOLD:
        large_items.append(p)
    else:
        h = int(hashlib.sha256(os.path.basename(p).encode()).hexdigest(), 16)
        regular_buckets[h % NUM_BUCKETS].append(p)

# Layer 0: FHS 骨架; Layer 1..N: 均衡数据包（所有层直接从 /nix/store 流式写入 tar，零磁盘中转拷贝）
layer_specs = [("skeleton", [skeleton_dir])] + [
    (f"bucket-{i:02d}", items)
    for i, items in enumerate([[p] for p in large_items] + [b for b in regular_buckets if b])
]

os.makedirs("/tmp/layers", exist_ok=True)

def build_single_layer(args):
    idx, name, paths = args
    layer_tar = f"/tmp/layers/layer_{idx:03d}.tar"
    sha = hashlib.sha256()

    with tarfile.open(layer_tar, "w") as tf:
        if name == "skeleton":
            for root, dirs, files in os.walk(paths[0], followlinks=False):
                rel_root = os.path.relpath(root, paths[0])
                for item in sorted(dirs + files):
                    full = os.path.join(root, item)
                    arcname = item if rel_root == "." else os.path.join(rel_root, item)
                    ti = tf.gettarinfo(full, arcname=arcname)
                    ti.uid = ti.gid = 0
                    ti.uname = ti.gname = "root"
                    ti.mtime = 0
                    if ti.isreg():
                        with open(full, "rb") as fobj:
                            tf.addfile(ti, fobj)
                    else:
                        tf.addfile(ti)
        else:
            # 确保父目录存在
            for d in ["usr", "usr/nix", "usr/nix/store"]:
                ti = tarfile.TarInfo(name=d)
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                ti.mtime = 0
                tf.addfile(ti)
            for sp in paths:
                base = os.path.basename(sp)
                for root, dirs, files in os.walk(sp, followlinks=False):
                    rel_sub = os.path.relpath(root, sp)
                    arc_dir = f"usr/nix/store/{base}" if rel_sub == "." else f"usr/nix/store/{base}/{rel_sub}"
                    ti_d = tf.gettarinfo(root, arcname=arc_dir)
                    ti_d.uid = ti_d.gid = 0
                    ti_d.mode = 0o755
                    ti_d.mtime = 0
                    tf.addfile(ti_d)
                    for fn in sorted(files):
                        full = os.path.join(root, fn)
                        arcname = f"{arc_dir}/{fn}"
                        ti = tf.gettarinfo(full, arcname=arcname)
                        ti.uid = ti.gid = 0
                        ti.mtime = 0
                        if ti.issym() and ti.linkname.startswith("/nix/store/"):
                            ti.linkname = "/usr" + ti.linkname
                        if ti.isreg():
                            with open(full, "rb") as fobj:
                                tf.addfile(ti, fobj)
                        else:
                            tf.addfile(ti)

    with open(layer_tar, "rb") as f:
        while chunk := f.read(1024 * 1024):
            sha.update(chunk)
    digest = sha.hexdigest()
    final_layer_name = f"{digest}.tar"
    os.rename(layer_tar, f"/tmp/layers/{final_layer_name}")
    return idx, final_layer_name, f"sha256:{digest}"

with ThreadPoolExecutor(max_workers=4) as pool:
    results = sorted(pool.map(build_single_layer, [(i, n, p) for i, (n, p) in enumerate(layer_specs)]))

layer_files = [r[1] for r in results]
diff_ids = [r[2] for r in results]

config_obj = {
    "architecture": "amd64",
    "os": "linux",
    "config": {
        "Cmd": ["/usr/lib/systemd/systemd"],
        "Labels": {"containers.bootc": "1"}
    },
    "rootfs": {"type": "layers", "diff_ids": diff_ids}
}
config_bytes = json.dumps(config_obj, separators=(",", ":")).encode()
config_digest = hashlib.sha256(config_bytes).hexdigest()
config_filename = f"{config_digest}.json"
with open(f"/tmp/layers/{config_filename}", "wb") as cf:
    cf.write(config_bytes)

manifest_obj = [{
    "Config": config_filename,
    "RepoTags": ["my-nixos-cli-bootc-vm:latest"],
    "Layers": layer_files
}]
with open("/tmp/layers/manifest.json", "wb") as mf:
    mf.write(json.dumps(manifest_obj, separators=(",", ":")).encode())

# 封装为标准 docker-archive 供 skopeo copy 直接流式推送
with tarfile.open(out_tar, "w") as archive:
    archive.add("/tmp/layers/manifest.json", arcname="manifest.json")
    archive.add(f"/tmp/layers/{config_filename}", arcname=config_filename)
    for lf in layer_files:
        archive.add(f"/tmp/layers/{lf}", arcname=lf)

print(f">>> Built {len(layer_files)} balanced layers directly into {out_tar}")
EOF
''
