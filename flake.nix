{
  description = "Declarative Pure-FHS openSUSE bootc image builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      spec = import ./packages.nix;

      # 自动化依赖解析与 SHA256 锁定脚本（运行 `nix run .#lock` 时触发）
      lockScript = pkgs.writeShellApplication {
        name = "lock-opensuse-rpms";
        runtimeInputs = [ pkgs.podman pkgs.python3 pkgs.jq pkgs.skopeo ];
        text = ''
          set -euo pipefail
          echo ">>> 1. 解析基础镜像 Digest 与 Nix SHA256..."
          BASE_REF="${spec.baseImage.name}:${spec.baseImage.tag}"
          DIGEST=$(skopeo inspect --format '{{.Digest}}' "docker://$BASE_REF")
          NIX_SHA256=$(nix-prefetch-url --unpack "docker://$BASE_REF" 2>/dev/null || echo "")

          echo ">>> 2. 在临时容器中运行 Zypper 计算完整依赖闭包..."
          TMP_DIR=$(mktemp -d)
          trap 'rm -rf "$TMP_DIR"' EXIT

          # 将 packages.nix 里的源和包列表导出为 JSON 传给容器内脚本
          cat <<'EOF' > "$TMP_DIR/spec.json"
          ${builtins.toJSON spec}
          EOF

          # 利用基础镜像内的 zypper + python 解析 repodata 获取所有依赖包的精准 URL 和 checksum
          podman run --rm -v "$TMP_DIR:/work:Z" "$BASE_REF" /bin/bash -c '
            set -e
            python3 - << "PYEOF"
          import json, subprocess, urllib.request, gzip, xml.etree.ElementTree as ET, os

          with open("/work/spec.json") as f:
              spec = json.load(f)

          # 添加源并刷新元数据
          for r in spec["repos"]:
              subprocess.run(["zypper", "--non-interactive", "ar", "-cf", "-p", str(r["priority"]), r["url"], r["name"]], check=False)
          subprocess.run(["zypper", "--non-interactive", "--gpg-auto-import-keys", "refresh"], check=True)

          # 使用 zypper --xmlout 模拟安装，获取精确的待安装包名与版本列表
          cmd = ["zypper", "--non-interactive", "--xmlout", "install", "--dry-run", "--no-recommends", "--"] + spec["rpmPackages"]
          res = subprocess.run(cmd, capture_output=True, text=True, check=True)
          root = ET.fromstring(res.stdout)

          targets = {}
          for solvable in root.findall(".//solvable[@type=\"package\"][@status=\"to-be-installed\"]"):
              name = solvable.attrib["name"]
              evr = solvable.attrib["edition"]
              arch = solvable.attrib["arch"]
              repo = solvable.attrib["repository"]
              targets[(name, evr, arch)] = repo

          # 从本地已刷新的 zypper raw cache (/var/cache/zypp/raw) 提取精确 href 与 sha256
          repo_urls = {r["name"]: r["url"].rstrip("/") for r in spec["repos"]}
          locked_rpms = []

          for repo_alias, base_url in repo_urls.items():
              repomd_path = f"/var/cache/zypp/raw/{repo_alias}/repodata/repomd.xml"
              if not os.path.exists(repomd_path):
                  continue
              rmd = ET.parse(repomd_path).getroot()
              ns = {"r": "http://linux.duke.edu/metadata/repo"}
              primary_loc = rmd.find(".//r:data[@type=\"primary\"]/r:location", ns).attrib["href"]
              primary_path = f"/var/cache/zypp/raw/{repo_alias}/{primary_loc}"

              with gzip.open(primary_path, "rb") as gz:
                  p_root = ET.parse(gz).getroot()
              pns = {"c": "http://linux.duke.edu/metadata/common"}
              for pkg in p_root.findall("c:package", pns):
                  name = pkg.find("c:name", pns).text
                  arch = pkg.find("c:arch", pns).text
                  ver_el = pkg.find("c:version", pns)
                  epoch = ver_el.attrib.get("epoch", "0")
                  ver = ver_el.attrib["ver"]
                  rel = ver_el.attrib["rel"]
                  evr = f"{ver}-{rel}" if epoch == "0" else f"{epoch}:{ver}-{rel}"

                  if (name, evr, arch) in targets and targets[(name, evr, arch)] == repo_alias:
                      csum = pkg.find("c:checksum", pns).text
                      href = pkg.find("c:location", pns).attrib["href"]
                      locked_rpms.append({
                          "name": name,
                          "evr": evr,
                          "url": f"{base_url}/{href}",
                          "sha256": csum
                      })

          locked_rpms.sort(key=lambda x: x["name"])
          with open("/work/locked_rpms.json", "w") as out:
              json.dump(locked_rpms, out, indent=2)
          print(f"成功锁定 {len(locked_rpms)} 个 RPM 包及其 SHA256！")
          PYEOF
          '

          # 3. 合成最终的 rpms.lock.json
          jq -n \
            --arg imgName "${spec.baseImage.name}" \
            --arg imgTag "${spec.baseImage.tag}" \
            --arg imgDigest "$DIGEST" \
            --slurpfile rpms "$TMP_DIR/locked_rpms.json" \
            '{
              baseImage: { name: $imgName, tag: $imgTag, digest: $imgDigest },
              rpms: $rpms[0]
            }' > rpms.lock.json

          echo ">>> 完成！已生成确定性锁文件: rpms.lock.json"
        '';
      };

    in
    {
      # App 1: 运行 `nix run .#lock` 自动刷新所有包的版本和 SHA256
      apps.${system}.lock = {
        type = "app";
        program = "${lockScript}/bin/lock-opensuse-rpms";
      };

      # Package 1: 运行 `nix build` 直接读取 rpms.lock.json 构建纯 FHS bootc 镜像
      packages.${system}.default =
        let
          lockData = builtins.fromJSON (builtins.readFile ./rpms.lock.json);
        in
        import ./image.nix {
          inherit pkgs lockData;
        };
    };
}
