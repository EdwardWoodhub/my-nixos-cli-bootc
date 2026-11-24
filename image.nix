{ pkgs ? import <nixpkgs> {}
, lockData ? builtins.fromJSON (builtins.readFile ./rpms.lock.json)
}:

let
  imageRepo = "ghcr.io/edwardwoodhub/my-opensuse-fhs-bootc";
  imageTag = "latest";
  passwordHash = "$6$3HzcniSmLcqcdDAD$XaGco3Esx69ux6SgsKCac/TWld3/L8ADC1I7eZRtaMvsPfNeb0cb6doyXP2qeyw6DOjVK.BluxZfQcAD/qR6e.";

  # 1. 拉取确定性基础镜像（不包含任何 /nix/store）
  baseImage = pkgs.dockerTools.pullImage {
    imageName = lockData.baseImage.name;
    imageDigest = lockData.baseImage.digest;
    sha256 = lockData.baseImage.sha256;
    finalImageName = "opensuse-leap";
    finalImageTag = lockData.baseImage.tag;
  };

  # 2. 将单个 RPM 声明转换为独立的 FHS 目录 Derivation（实现包粒度缓存复用）
  unpackRpm = rpmSpec: pkgs.runCommand "fhs-rpm-${rpmSpec.name}-${rpmSpec.evr}" {
    nativeBuildInputs = [ pkgs.rpmextract ];
    src = pkgs.fetchurl {
      url = rpmSpec.url;
      sha256 = rpmSpec.sha256;
    };
  } ''
    mkdir -p $out
    cd $out
    rpmextract $src
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

  # 3. 声明式系统配置层（/etc, systemd 服务, 用户目录与 bootc 规范化）
  systemConfigLayer = pkgs.runCommand "fhs-system-config" {} ''
    mkdir -p $out/etc/profile.d \
             $out/etc/dracut.conf.d \
             $out/etc/systemd/system/multi-user.target.wants \
             $out/var/home/peter/winShare \
             $out/var/home/liveuser

    # 暴露 /usr/local/bin、/usr/sbin 与 /sbin
    cat <<'EOF' > $out/etc/profile.d/custom-sbin-path.sh
    export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin"
    EOF
    chmod 644 $out/etc/profile.d/custom-sbin-path.sh

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

  # buildLayeredImage 默认即在 fakeRoot 下运行，无需 enableFakeRoot 参数
  fakeRootCommands = ''
    # 1. 遵循 OSTree / bootc 规范将 /home 指向 /var/home
    rm -rf home
    ln -s var/home home

    # 2. 创建用户并注入加盐哈希密码
    grep -q '^wheel:' etc/group || echo 'wheel:x:10:' >> etc/group
    echo 'liveuser:x:1000:100::/var/home/liveuser:/bin/bash' >> etc/passwd
    echo 'peter:x:1001:100::/var/home/peter:/bin/bash' >> etc/passwd
    echo 'liveuser:${passwordHash}:19000:0:99999:7:::' >> etc/shadow
    echo 'peter:${passwordHash}:19000:0:99999:7:::' >> etc/shadow
    sed -i 's|^root:[^:]*:|root:${passwordHash}:|' etc/shadow
    sed -i 's|^wheel:x:10:.*|wheel:x:10:liveuser,peter|' etc/group
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' >> etc/sudoers
    chown -R 1000:100 var/home/liveuser
    chown -R 1001:100 var/home/peter

    # 3. 合并 os-release 元数据
    cat usr/lib/os-release.append >> usr/lib/os-release
    rm -f usr/lib/os-release.append

    # 4. 满足 bootc 内核路径规范 (/usr/lib/modules/<kver>/vmlinuz)
    KVER=$(ls -1 usr/lib/modules | head -n 1)
    if [ -n "$KVER" ] && [ -f "boot/vmlinuz-$KVER" ]; then
      mv "boot/vmlinuz-$KVER" "usr/lib/modules/$KVER/vmlinuz"
    fi
    rm -rf boot/*
  '';

  config = {
    Cmd = [ "/sbin/init" ];
  };
}
