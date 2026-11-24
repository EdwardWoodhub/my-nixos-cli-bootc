{
  baseImage = {
    name = "registry.opensuse.org/opensuse/leap";
    tag = "16.0";
  };

  # 1. openSUSE 软件源定义（新增 Virtualization:containers 源以获取 bootc 和 ostree）
  repos = [
    { name = "oss"; url = "https://download.opensuse.org/distribution/leap/16.0/repo/oss/"; priority = 90; }
    { name = "non-oss"; url = "https://download.opensuse.org/distribution/leap/16.0/repo/non-oss/"; priority = 90; }
    { name = "M17N-fonts"; url = "https://download.opensuse.org/repositories/M17N:/fonts/16.0/"; priority = 95; }
    { name = "utilities"; url = "https://download.opensuse.org/repositories/utilities/16.0/"; priority = 95; }
    { name = "factory"; url = "https://download.opensuse.org/repositories/openSUSE:/Factory/standard/"; priority = 115; }
    { name = "virt-containers"; url = "https://download.opensuse.org/repositories/Virtualization:/containers/openSUSE_Tumbleweed/"; priority = 120; }
  ];

  # 2. 声明需要的 RPM 包名（移除不存在的 ostree-grub2 和缺源的 uv，uv 改用 Nix 静态二进制注入）
  rpmPackages = [
    "shim"
    "bootc"
    "ostree"
    "7zip"
    "bandwhich"
    "btop"
    "btrfsprogs"
    "curl"
    "dbus-1-tools"
    "device-mapper"
    "dosfstools"
    "dracut"
    "e2fsprogs"
    "fastfetch"
    "findutils"
    "gptfdisk"
    "grub2"
    "grub2-x86_64-efi"
    "gzip"
    "htop"
    "iotop"
    "iproute2"
    "kernel-default"
    "less"
    "mtools"
    "nano"
    "nethogs"
    "NetworkManager"
    "openssh-clients"
    "openssh-server"
    "open-vm-tools"
    "parted"
    "podman"
    "python3"
    "rsync"
    "sed"
    "sudo"
    "syncthing"
    "systemd"
    "tar"
    "timezone"
    "tmux"
    "vim"
    "which"
  ];
}
