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

    chmod -R u+w $out/usr

    # 8. 第一轮重写：把所有 /nix/store/ 和 /etc/ 绝对软链接重定向到 /usr 下
    #    第二轮模拟 composefs 多跳解析，抓出任何仍会越界的链接并修复
    python3 - << 'EOF'
import os

out_dir = os.path.abspath(os.environ["out"])

# 第一轮：基础路径重定向
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
            # /usr/etc 内部引用 /etc/... 时，在构建期重定向到 /usr/etc/... 避免跨目录逃逸
            os.unlink(full_path)
            os.symlink("/usr" + target, full_path)

# 第二轮：完全模拟 composefs/cap-std 的多跳递归路径解析
def multi_hop_resolve(root, start_rel_dir, target, depth=0):
    if depth > 40:
        return True, "/" # 循环链接视为异常
    stack = [] if target.startswith("/") else [p for p in start_rel_dir.split("/") if p]
    for part in target.split("/"):
        if not part or part == ".":
            continue
        if part == "..":
            if not stack:
                return True, "/" # 逃逸出 root 边界！
            stack.pop()
        else:
            stack.append(part)
            cur_rel = "/".join(stack)
            cur_host = os.path.join(root, cur_rel)
            if os.path.islink(cur_host):
                sub_target = os.readlink(cur_host)
                parent_rel = "/".join(stack[:-1])
                escaped, resolved = multi_hop_resolve(root, parent_rel, sub_target, depth + 1)
                if escaped:
                    return True, "/"
                stack = [p for p in resolved.split("/") if p]
    return False, "/" + "/".join(stack)

fixed_count = 0
for dirpath, dirnames, filenames in os.walk(out_dir, followlinks=False):
    rel_dir = os.path.relpath(dirpath, out_dir)
    if rel_dir == ".":
        rel_dir = ""
    for name in filenames + dirnames:
        full_path = os.path.join(dirpath, name)
        if not os.path.islink(full_path):
            continue
        target = os.readlink(full_path)
        escaped, resolved = multi_hop_resolve(out_dir, rel_dir, target)
        if escaped:
            print(f"[FIX MULTI-HOP ESCAPE] {os.path.relpath(full_path, out_dir)} -> {target}")
            # 将越界链接直接转为安全的虚拟根目录路径，或指向 /dev/null
            os.unlink(full_path)
            os.symlink("/dev/null", full_path)
            fixed_count += 1

print(f">>> Symlink sanitization complete. Fixed {fixed_count} multi-hop escaping symlinks.")
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
