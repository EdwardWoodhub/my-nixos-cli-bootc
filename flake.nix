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
          NIX_SHA256=$(nix-prefetch-docker --json --image-name "${spec.baseImage.name}" --image-digest "$DIGEST" --quiet | jq -r '.hash // .sha256')
          if [ -z "$NIX_SHA256" ] || [ "$NIX_SHA256" = "null" ]; then
            echo "错误: 无法解析基础镜像 Nix Hash"
            exit 1
          fi

          echo ">>> 2. 在临时容器中运行 Zypper 下载完整依赖闭包 (--download-only)..."
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
                zypper --non-interactive ar -cf -k -p ${toString r.priority} "${r.url}" "${r.name}" || true
              '') spec.repos}
              zypper --non-interactive --gpg-auto-import-keys refresh
              echo ">>> 正在解析并下载所有依赖 RPM 包..."
              zypper --non-interactive install --download-only --no-recommends --allow-vendor-change -- \
                ${pkgs.lib.escapeShellArgs spec.rpmPackages}
            '

          echo ">>> 3. 扫描 RPM 实体文件、计算 SHA256 并直接预注入本地 Nix Store..."
          TMP_DIR="$TMP_DIR" python3 - << 'PYEOF'
          import json, hashlib, os, subprocess

          tmp_dir = os.environ["TMP_DIR"]
          with open(f"{tmp_dir}/spec.json") as f:
              spec = json.load(f)

          repo_urls = {r["name"]: r["url"].rstrip("/") for r in spec["repos"]}
          pkg_root = f"{tmp_dir}/zypp-cache/packages"
          locked_rpms = []

          if os.path.exists(pkg_root):
              for repo_alias in os.listdir(pkg_root):
                  if repo_alias not in repo_urls:
                      continue
                  base_url = repo_urls[repo_alias]
                  repo_dir = os.path.join(pkg_root, repo_alias)
                  for root, _, files in os.walk(repo_dir):
                      for fname in files:
                          if not fname.endswith(".rpm"):
                              continue
                          full_path = os.path.join(root, fname)
                          rel_path = os.path.relpath(full_path, repo_dir)

                          # 直接将已下载的 RPM 注入 Nix Store，防止后续 fetchurl 遭遇滚动源 404
                          subprocess.run(["nix-store", "--add-fixed", "sha256", full_path], check=True, stdout=subprocess.DEVNULL)

                          h = hashlib.sha256()
                          with open(full_path, "rb") as rf:
                              for chunk in iter(lambda: rf.read(65536), b""):
                                  h.update(chunk)

                          stem = fname[:-4]
                          parts = stem.rsplit("-", 2)
                          pkg_name = parts[0] if len(parts) == 3 else stem
                          evr = f"{parts[1]}-{parts[2]}" if len(parts) == 3 else "latest"

                          locked_rpms.append({
                              "name": pkg_name,
                              "evr": evr,
                              "url": f"{base_url}/{rel_path}",
                              "sha256": h.hexdigest()
                          })

          if not locked_rpms:
              raise RuntimeError("错误: 未在 zypp 缓存中找到任何下载的 RPM 文件！")

          locked_rpms.sort(key=lambda x: x["name"])
          with open(f"{tmp_dir}/locked_rpms.json", "w") as out:
              json.dump(locked_rpms, out, indent=2)
          print(f"成功锁定并预缓存 {len(locked_rpms)} 个 RPM 包！")
          PYEOF

          # 4. 合成最终的 rpms.lock.json
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
