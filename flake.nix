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
        runtimeInputs = [ pkgs.python3 pkgs.jq pkgs.nix-prefetch-docker ];
        text = ''
          set -euo pipefail
          echo ">>> 1. 解析基础镜像 Digest 与 Nix SHA256..."
          PREFETCH_JSON=$(nix-prefetch-docker --json --image-name "${spec.baseImage.name}" --image-tag "${spec.baseImage.tag}" --quiet)
          DIGEST=$(echo "$PREFETCH_JSON" | jq -r '.imageDigest')
          NIX_SHA256=$(echo "$PREFETCH_JSON" | jq -r '.sha256')

          echo ">>> 2. 在临时容器中运行 Zypper 计算完整依赖闭包..."
          TMP_DIR=$(mktemp -d)
          trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT
          mkdir -p "$TMP_DIR/zypp-cache"

          cat <<'EOF' > "$TMP_DIR/spec.json"
          ${builtins.toJSON spec}
          EOF

          docker run --rm \
            -v "$TMP_DIR:/work" \
            -v "$TMP_DIR/zypp-cache:/var/cache/zypp" \
            "${spec.baseImage.name}:${spec.baseImage.tag}" /bin/bash -c '
              trap "chmod -R 777 /work /var/cache/zypp 2>/dev/null || true" EXIT
              set -e
              ${pkgs.lib.concatMapStringsSep "\n" (r: ''
                zypper --non-interactive ar -cf -p ${toString r.priority} "${r.url}" "${r.name}" || true
              '') spec.repos}
              zypper --non-interactive --gpg-auto-import-keys refresh
              echo ">>> 正在执行 Zypper 依赖求解 (dry-run)..."
              if ! zypper --non-interactive --xmlout install --dry-run --no-recommends --allow-vendor-change -- \
                ${pkgs.lib.escapeShellArgs spec.rpmPackages} > /work/zypper_out.xml 2> /work/zypper_err.log; then
                echo "=== Zypper 依赖求解报错详情 ==="
                cat /work/zypper_err.log
                cat /work/zypper_out.xml
                exit 1
              fi
            '

          echo ">>> 3. 使用 Nix Python 解析 repodata 提取所有依赖 URL 与 SHA256..."
          TMP_DIR="$TMP_DIR" python3 - << 'PYEOF'
          import json, gzip, io, xml.etree.ElementTree as ET, os
          from compression import zstd

          def open_metadata(path):
              with open(path, "rb") as f:
                  magic = f.read(4)
              if magic.startswith(b"\x28\xb5\x2f\xfd"):
                  return zstd.open(path, "rb")
              elif magic.startswith(b"\x1f\x8b"):
                  return gzip.open(path, "rb")
              else:
                  return open(path, "rb")

          tmp_dir = os.environ["TMP_DIR"]
          with open(f"{tmp_dir}/spec.json") as f:
              spec = json.load(f)

          root = ET.parse(f"{tmp_dir}/zypper_out.xml").getroot()

          targets = {}
          for solvable in root.findall(".//solvable[@type='package'][@status='to-be-installed']"):
              name = solvable.attrib["name"]
              evr = solvable.attrib["edition"]
              arch = solvable.attrib["arch"]
              repo = solvable.attrib["repository"]
              targets[(name, evr, arch)] = repo

          repo_urls = {r["name"]: r["url"].rstrip("/") for r in spec["repos"]}
          locked_rpms = []

          for repo_alias, base_url in repo_urls.items():
              repomd_path = f"{tmp_dir}/zypp-cache/raw/{repo_alias}/repodata/repomd.xml"
              if not os.path.exists(repomd_path):
                  continue
              rmd = ET.parse(repomd_path).getroot()
              ns = {"r": "http://linux.duke.edu/metadata/repo"}
              primary_loc = rmd.find(".//r:data[@type='primary']/r:location", ns).attrib["href"]
              primary_path = f"{tmp_dir}/zypp-cache/raw/{repo_alias}/{primary_loc}"

              with open_metadata(primary_path) as meta_f:
                  p_root = ET.parse(meta_f).getroot()
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
          with open(f"{tmp_dir}/locked_rpms.json", "w") as out:
              json.dump(locked_rpms, out, indent=2)
          print(f"成功锁定 {len(locked_rpms)} 个 RPM 包及其 SHA256！")
          PYEOF

          # 4. 合成最终的 rpms.lock.json（包含 imageDigest 和 nix sha256）
          jq -n \
            --arg imgName "${spec.baseImage.name}" \
            --arg imgTag "${spec.baseImage.tag}" \
            --arg imgDigest "$DIGEST" \
            --arg imgSha256 "$NIX_SHA256" \
            --slurpfile rpms "$TMP_DIR/locked_rpms.json" \
            '{
              baseImage: { name: $imgName, tag: $imgTag, digest: $imgDigest, sha256: $imgSha256 },
              rpms: $rpms[0]
            }' > rpms.lock.json

          echo ">>> 完成！已生成确定性锁文件: rpms.lock.json"
        '';
      };

    in
    {
      # 运行 `nix run .#lock` 自动解析并锁定所有包版本和 SHA256
      apps.${system}.lock = {
        type = "app";
        program = "${lockScript}/bin/lock-opensuse-rpms";
      };

      # 运行 `nix build` 读取 rpms.lock.json 构建纯 FHS bootc 镜像
      packages.${system}.default =
        let
          lockData = builtins.fromJSON (builtins.readFile ./rpms.lock.json);
        in
        import ./image.nix {
          inherit pkgs lockData;
        };
    };
}
