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
    nativeBuildInputs = [ pkgs.rsync pkgs.coreutils pkgs.bootc ];
  } ''
    mkdir -p $out/usr/{bin,sbin,lib,lib64,share,etc,nix/store}
    mkdir -p $out/nix/store $out/var $out/run $out/tmp $out/proc $out/sys $out/dev $out/boot

    # 1. 创建标准的 UsrMerge 顶层符号链接（bootc container lint 强制校验）
    ln -s usr/bin $out/bin
    ln -s usr/sbin $out/sbin
    ln -s usr/lib $out/lib
    ln -s usr/lib64 $out/lib64

    # 2. 暴露标准的 FHS 接口（将聚合后的软件树链接到 /usr 下）
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

    # 8. 构建期直接执行 bootc 结构体检（无需启动容器，耗时约 2 秒）
    echo ">>> Running bootc container lint..."
    bootc container lint --rootfs=$out
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "my-nixos-cli-bootc-vm";
  tag = "latest";

  maxLayers = 100;

  contents = [ bootcLayout ];

  # 清理 buildLayeredImage 自动带入的顶层 /nix/store 副本，只保留空挂载点，避免镜像体积翻倍
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
