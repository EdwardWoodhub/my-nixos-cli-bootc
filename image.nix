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

  # 获取当前系统闭包的完整路径列表
  closureInfo = pkgs.closureInfo {
    rootPaths = [ toplevel modulesTree ];
  };

  # 构建符合 bootc 强制规范的 UsrMerge FHS 骨架与系统布局
  bootcLayout = pkgs.runCommand "nixos-bootc-fhs-layout" {
    nativeBuildInputs = [ pkgs.rsync pkgs.coreutils pkgs.bootc pkgs.python3 ];
  } ''
    mkdir -p $out/usr/{bin,sbin,lib,lib64,share,etc,nix/store}
    mkdir -p $out/nix/store $out/var $out/run $out/tmp $out/proc $out/sys $out/dev $out/boot

    # 1. 创建标准的 UsrMerge 顶层符号链接
    ln -s usr/bin $out/bin
    ln -s usr/sbin $out/sbin
    ln -s usr/lib $out/lib
    ln -s usr/lib64 $out/lib64

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

    # 7. 将闭包中的所有 /nix/store 实体复制到只读的 /usr/nix/store
    while IFS= read -r store_path; do
      cp -a "$store_path" "$out/usr/nix/store/"
    done < ${closureInfo}/store-paths

    # 赋予构建者写权限，以便后续脚本规范化符号链接
    chmod -R u+w $out/usr

    # 8. 全面规范化符号链接并检测任何逃逸出 $out 根目录的链接
    python3 - << 'EOF'
import os

out_dir = os.path.abspath(os.environ["out"])

def resolve_in_chroot(root, link_path, target):
    """模拟 chroot 环境下解析符号链接，判断是否会逃逸出 root 边界"""
    cur_dir = os.path.dirname(link_path)
    parts = target.split("/")
    if target.startswith("/"):
        cur_rel = ""
    else:
        cur_rel = os.path.relpath(cur_dir, root)
        if cur_rel == ".":
            cur_rel = ""

    stack = [p for p in cur_rel.split("/") if p]
    escaped = False
    for p in parts:
        if not p or p == ".":
            continue
        if p == "..":
            if not stack:
                escaped = True
            else:
                stack.pop()
        else:
            stack.append(p)
    return escaped, "/" + "/".join(stack)

for dirpath, dirnames, filenames in os.walk(out_dir, followlinks=False):
    for name in filenames + dirnames:
        full_path = os.path.join(dirpath, name)
        if not os.path.islink(full_path):
            continue
        target = os.readlink(full_path)

        # 规则 A: 重定向 /nix/store/ -> /usr/nix/store/
        if target.startswith("/nix/store/"):
            target = "/usr" + target
            os.unlink(full_path)
            os.symlink(target, full_path)

        # 规则 B: 重定向 /etc/ -> /usr/etc/ (排除 /etc/mtab, /etc/resolv.conf 等运行时动态文件)
        elif target.startswith("/etc/static/"):
            target = "/usr" + target
            os.unlink(full_path)
            os.symlink(target, full_path)

        # 规则 C: 检查是否仍存在 ../ 逃逸出虚拟根目录的链接，将其规范化为安全的虚拟绝对路径
        escaped, norm_target = resolve_in_chroot(out_dir, full_path, target)
        if escaped:
            print(f"[FIX ESCAPED SYMLINK] {os.path.relpath(full_path, out_dir)} -> {target}  ==>  {norm_target}")
            os.unlink(full_path)
            os.symlink(norm_target, full_path)
EOF

    # 9. 构建期直接执行 bootc 结构体检
    echo ">>> Running bootc container lint..."
    bootc container lint --rootfs=$out
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "my-nixos-cli-bootc-vm";
  tag = "latest";

  maxLayers = 100;

  contents = [ bootcLayout ];

  extraCommands = ''
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
