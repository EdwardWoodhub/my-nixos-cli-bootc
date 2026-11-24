{ pkgs ? import <nixpkgs> {}
, lockData ? builtins.fromJSON (builtins.readFile ./rpms.lock.json)
}:

let
  imageRepo = "ghcr.io/edwardwoodhub/my-opensuse-fhs-bootc";
  imageTag = "latest";

  # 1. 拉取确定性基础镜像（不包含任何 /nix/store）
  baseImage = pkgs.dockerTools.pullImage {
    imageName = lockData.baseImage.name;
    imageDigest = lockData.baseImage.digest;
    sha256 = lockData.baseImage.sha256;
    finalImageName = "opensuse-leap";
    finalImageTag = lockData.baseImage.tag;
  };

  # 2. 将单个 RPM 声明转换为独立的 FHS 目录 Derivation（剥离 SUID/SGID 以符合 Nix Store 规范）
  unpackRpm = rpmSpec: pkgs.runCommand "fhs-rpm-${rpmSpec.name}-${rpmSpec.evr}" {
    nativeBuildInputs = [ pkgs.rpm pkgs.cpio pkgs.fakeroot ];
    src = pkgs.fetchurl {
      url = rpmSpec.url;
      sha256 = rpmSpec.sha256;
    };
  } ''
    mkdir -p $out
    cd $out
    fakeroot bash -c 'rpm2cpio "$1" | cpio -idm --no-preserve-owner --quiet' _ "$src"
    chmod -R ug-s . || true

    # 规范化 UsrMerge（防止部分旧 RPM 往 /bin /sbin /lib 写文件导致 OSTree 报错）
    for dir in bin sbin lib lib64; do
      if [ -d "$dir" ] && [ ! -L "$dir" ]; then
        mkdir -p "usr/$dir"
        cp -a "$dir/." "usr/$dir/"
        rm -rf "$dir"
      fi
    done
  '';

  unpackedRpms = map unpackRpm lockData.rpms;

  # 3. 声明式系统配置层（/etc 独立配置文件、systemd 服务与元数据暂存）
  systemConfigLayer = pkgs.runCommand "fhs-system-config" {} ''
    mkdir -p $out/etc/profile.d \
             $out/etc/sudoers.d \
             $out/etc/dracut.conf.d \
             $out/etc/systemd/system/multi-user.target.wants

    # 暴露 /usr/local/bin、/usr/sbin 与 /sbin
    cat <<'EOF' > $out/etc/profile.d/custom-sbin-path.sh
    export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin"
    EOF
    chmod 644 $out/etc/profile.d/custom-sbin-path.sh

    # 免密 wheel sudo 独立配置
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' > $out/etc/sudoers.d/90-wheel-nopasswd
    echo 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' >> $out/etc/sudoers.d/90-wheel-nopasswd
    chmod 440 $out/etc/sudoers.d/90-wheel-nopasswd

    # Dracut 通用与 OSTree 模块配置
    echo 'hostonly="no"' > $out/etc/dracut.conf.d/02-generic.conf
    echo 'add_dracutmodules+=" ostree "' > $out/etc/dracut.conf.d/03-ostree.conf

    # VMware 共享文件夹自动挂载服务
    cat <<'EOF' > $out/etc/systemd/system/mnt-winShare.service
    [Unit]
    Description=Mount VMware Shared Folder (winShare)
    ConditionVirtualization=vmware
    Requires=vmtoolsd.service
    After=vmtoolsd.service network.target local-fs.target

    [Service]
    Type=oneshot
    ExecStartPre=/usr/bin/mkdir -p /var/home/peter/winShare
    ExecStart=/usr/bin/vmhgfs-fuse .host:/ /var/home/peter/winShare -o subtype=vmhgfs-fuse,allow_other
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    EOF

    # 声明式启用系统服务（直接建立 systemd wants 软链接）
    ln -sf /etc/systemd/system/mnt-winShare.service $out/etc/systemd/system/multi-user.target.wants/mnt-winShare.service
    ln -sf /usr/lib/systemd/system/sshd.service $out/etc/systemd/system/multi-user.target.wants/sshd.service
    ln -sf /usr/lib/systemd/system/NetworkManager.service $out/etc/systemd/system/multi-user.target.wants/NetworkManager.service
    ln -sf /usr/lib/systemd/system/vmtoolsd.service $out/etc/systemd/system/multi-user.target.wants/vmtoolsd.service

    # 写入 os-release 镜像追踪元数据暂存文件
    mkdir -p $out/usr/lib
    cat <<EOF > $out/usr/lib/os-release.append
    IMAGE_REPO="${imageRepo}"
    IMAGE_TAG="${imageTag}"
    IMAGE="${imageRepo}:${imageTag}"
    EOF
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "my-opensuse-fhs-bootc";
  tag = imageTag;
  fromImage = baseImage;

  # 每个 RPM Derivation 自动分配独立 OCI Layer（最多 100 层），实现修改单个包秒级增量推送
  maxLayers = 100;
  contents = unpackedRpms ++ [ systemConfigLayer ];

  # fakeRootCommands 运行在独立的顶层目录中，仅创建 OSTree 标准 /home -> /var/home 映射
  fakeRootCommands = ''
    mkdir -p var/home
    ln -s var/home home
  '';

  config = {
    Cmd = [ "/sbin/init" ];
  };
}
