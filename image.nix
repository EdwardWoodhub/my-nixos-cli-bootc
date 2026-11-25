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

  # 获取当前系统闭包的完整路径列表
  closureInfo = pkgs.closureInfo {
    rootPaths = [ toplevel ];
  };

  # 构建符合 bootc 强制规范的 UsrMerge FHS 骨架与系统布局
  bootcLayout = pkgs.runCommand "nixos-bootc-fhs-layout" {
    nativeBuildInputs = [ pkgs.rsync pkgs.coreutils ];
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

    # 3. 提供标准 FHS 动态链接器（使外部二进制无需 nix-ld 即可直接执行）
    ln -sf ${pkgs.stdenv.cc.libc}/lib/ld-linux-x86-64.so.2 $out/usr/lib64/ld-linux-x86-64.so.2

    # 4. 暴露 systemd 单元与 udev 规则到标准 /usr/lib 路径
    mkdir -p $out/usr/lib/systemd/system $out/usr/lib/udev/rules.d
    cp -rsf ${toplevel}/etc/systemd/system/* $out/usr/lib/systemd/system/ 2>/dev/null || true
    cp -rsf ${toplevel}/etc/udev/rules.d/* $out/usr/lib/udev/rules.d/ 2>/dev/null || true

    # 5. 生成 OSTree 规范的 /usr/etc（bootc 启动时自动三方合并至 /etc）
    rsync -aL --ignore-errors ${toplevel}/etc/ $out/usr/etc/ || true
    cp -L ${toplevel}/etc/os-release $out/usr/lib/os-release

    # 6. 按照 bootc 规范放置内核、initramfs 与内核模块
    mkdir -p $out/usr/lib/modules/${kver}
    cp -L ${kernel}/bzImage $out/usr/lib/modules/${kver}/vmlinuz
    cp -L ${initrd} $out/usr/lib/modules/${kver}/initramfs.img
    rsync -aL ${kernel}/lib/modules/${kver}/ $out/usr/lib/modules/${kver}/

    # 7. 将闭包中的所有 /nix/store 实体复制到只读的 /usr/nix/store
    while IFS= read -r store_path; do
      cp -a "$store_path" "$out/usr/nix/store/"
    done < ${closureInfo}/store-paths
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "my-nixos-xfce-vm";
  tag = "latest";

  # 最大化层数切分，确保每次更新只有变动的 Nix 派生触发新层下载
  maxLayers = 100;

  contents = [ bootcLayout ];

  config = {
    Cmd = [ "/usr/lib/systemd/systemd" ];
    Labels = {
      # 声明此镜像为标准的可启动 bootc 镜像
      "containers.bootc" = "1";
    };
  };
}
