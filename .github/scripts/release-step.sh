#!/usr/bin/env bash
set -euo pipefail

step="${1:?missing release step}"

case "$step" in
  checkout-source)
    auth="$(printf 'x-access-token:%s' "$IRIS_SOURCE_PAT" | base64 | tr -d '\n')"
    git init iris-src
    git -C iris-src remote add origin https://github.com/wuyilingwei/IRIS.git
    git -C iris-src -c http.extraheader="AUTHORIZATION: basic $auth" fetch --depth=1 origin "$IRIS_SOURCE_REF"
    git -C iris-src checkout --detach FETCH_HEAD
    cp .github/scripts/run-quiet.mjs iris-src/.workflow-run-quiet.mjs
    unset auth
    ;;
  metadata)
    echo "internal_version=$(node -p "require('./package.json').version")" >> "$GITHUB_OUTPUT"
    echo "commit=$(git rev-parse --short=12 HEAD)" >> "$GITHUB_OUTPUT"
    ;;
  install)
    npm ci
    npm --prefix frontend ci
    ;;
  generate-key)
    key="$(node scripts/generate-release-key.mjs)"
    test "${#key}" -eq 43
    test -n "$IRIS_RELEASE_KEY_TRANSFER_KEY"
    envelope="$(IRIS_RELEASE_KEY="$key" node scripts/transfer-release-key.mjs encrypt-base64)"
    test -n "$envelope"
    echo "envelope=$envelope" >> "$GITHUB_OUTPUT"
    echo "release_id=$(node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('base64url'))")" >> "$GITHUB_OUTPUT"
    ;;
  decrypt-key)
    key="$(node scripts/transfer-release-key.mjs decrypt-base64 "$IRIS_RELEASE_KEY_ENVELOPE")"
    test "${#key}" -eq 43
    echo "::add-mask::$key"
    printf 'IRIS_RELEASE_KEY=%s\n' "$key" >> "$GITHUB_ENV"
    ;;
  opaque-metadata)
    node -e "const fs=require('node:fs');const p=JSON.parse(fs.readFileSync('package.json','utf8'));p.version='0.0.0';fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\\n')"
    ;;
  build)
    eval "$DIST_CMD"
    ;;
  upload-artifacts)
    shopt -s nullglob
    case "$RUNNER_OS" in
      Windows)
        installer="$(node -e "const fs=require('node:fs');const value=fs.readFileSync(process.argv[1],'utf8').match(/^path:\\s*['\\\"]?([^'\\\"\\r\\n]+)['\\\"]?\\s*$/m)?.[1];if(!value)process.exit(1);process.stdout.write(value)" iris-src/release/latest.yml)"
        files=("iris-src/release/$installer")
        ;;
      macOS) files=(iris-src/release/*.dmg) ;;
      Linux) files=(iris-src/release/*.AppImage iris-src/release/*.deb) ;;
      *) exit 1 ;;
    esac
    test "${#files[@]}" -gt 0 && test -f "${files[0]}"
    gh release upload latest "${files[@]}" --clobber --repo "$GITHUB_REPOSITORY"
    ;;
  upload-key)
    echo "::add-mask::$IRIS_RELEASE_KEY"
    node scripts/upload-release-key.mjs
    ;;
  generate-manifest)
    gh api "repos/$GITHUB_REPOSITORY/releases/tags/latest" > release.json
    mkdir update-assets
    node <<'NODE'
const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { readFileSync, writeFileSync } = require('node:fs');

const release = JSON.parse(readFileSync('release.json', 'utf8'));
const allowed = /\.(exe|dmg|AppImage|deb)$/;
const assets = release.assets.filter((asset) => allowed.test(asset.name));
if (assets.length !== release.assets.length || assets.length === 0) {
  throw new Error('release contains unsupported or no installer assets');
}
const assetsByName = new Map();
for (const asset of assets) {
  const platform = asset.name.endsWith('.exe') ? 'windows'
    : asset.name.endsWith('.dmg') ? 'darwin' : 'linux';
  const arch = /-(x64|arm64|x86_64|amd64)\.(?:exe|dmg|AppImage|deb)$/.exec(asset.name)?.[1];
  if (!arch) throw new Error(`unable to determine asset architecture: ${asset.name}`);
  if (assetsByName.has(asset.name)) throw new Error(`duplicate update asset: ${asset.name}`);
  execFileSync('gh', ['release', 'download', 'latest', '--repo', process.env.GITHUB_REPOSITORY,
    '--pattern', asset.name, '--dir', 'update-assets'], { stdio: 'inherit' });
  assetsByName.set(asset.name, {
    name: asset.name,
    platform,
    arch,
    url: asset.browser_download_url,
    sha256: createHash('sha256').update(readFileSync(`update-assets/${asset.name}`)).digest('hex'),
    size: asset.size,
  });
}
const manifestAssets = [...assetsByName.values()];
if (!manifestAssets.some((asset) => asset.platform === 'windows')
  || !manifestAssets.some((asset) => asset.platform === 'darwin')) {
  throw new Error('release is missing required Windows or macOS installer assets');
}
writeFileSync('iris-update.json', `${JSON.stringify({
  release_id: process.env.IRIS_RELEASE_ID,
  assets: manifestAssets,
}, null, 2)}\n`);
NODE
    gh release upload latest iris-update.json --clobber --repo "$GITHUB_REPOSITORY"
    ;;
  *) exit 1 ;;
esac
