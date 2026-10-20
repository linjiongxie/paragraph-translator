#!/usr/bin/env bash
set -euo pipefail

release_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
release_version="${1:-0.1.1}"
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '版本必须采用 0.1.0 格式。\n' >&2
  exit 1
fi
release_app="${2:-$release_root/dist/段落翻译.app}"
release_binary="$release_app/Contents/MacOS/ParagraphTranslator"
if [[ ! -f "$release_binary" ]]; then
  printf '请先运行 bash scripts/build-app.sh 生成 release App。\n' >&2
  exit 1
fi
codesign --verify --strict "$release_app"
# Refuse binaries whose debugging records expose a local build-user directory.
python3 - "$release_binary" <<'PY'
from pathlib import Path
import sys

binary = Path(sys.argv[1]).read_bytes()
if any(prefix in binary for prefix in (b"/Users/", b"/home/")):
    raise SystemExit("发布二进制含本机用户目录；请使用 build-app.sh 清除调试符号后重新构建。")
PY
release_arch="$(lipo -archs "$release_binary")"
if [[ "$release_arch" != "arm64" && "$release_arch" != "x86_64" ]]; then
  printf '当前打包脚本只接受单架构 App，实际为：%s\n' "$release_arch" >&2
  exit 1
fi
release_app_version="$(plutil -extract CFBundleShortVersionString raw "$release_app/Contents/Info.plist")"
if [[ "$release_app_version" != "$release_version" ]]; then
  printf 'App 版本 %s 与指定版本 %s 不一致。\n' "$release_app_version" "$release_version" >&2
  exit 1
fi
release_dir="$release_root/release"
release_name="paragraph-translator-$release_version-macos-$release_arch"
release_archive="$release_dir/$release_name.zip"
mkdir -p "$release_dir"
if [[ -e "$release_archive" ]]; then
  printf '已存在发布包，请先检查：%s\n' "$release_archive" >&2
  exit 1
fi
release_stage="$(mktemp -d "${TMPDIR:-/tmp}/paragraph-translator-package.XXXXXX")"
trap 'rm -rf -- "$release_stage"' EXIT

# Preserve the existing signature without copying local extended attributes.
ditto --norsrc --noextattr --noqtn "$release_app" "$release_stage/段落翻译.app"
cp "$release_root/LICENSE" "$release_stage/LICENSE.txt"
cp "$release_root/INSTALL.md" "$release_stage/INSTALL.md"
# Python's ZIP writer marks non-ASCII names as UTF-8 and excludes xattrs.
python3 - "$release_stage" "$release_archive" <<'PY'
from pathlib import Path
import sys
import zipfile

source, output = map(Path, sys.argv[1:])
with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(source.rglob("*")):
        if path.name == ".DS_Store" or path.name.startswith("._"):
            continue
        archive.write(path, path.relative_to(source).as_posix())
PY
(
  cd "$release_dir"
  shasum -a 256 "$release_name.zip" > "$release_name.zip.sha256"
)
printf '已生成：%s\n' "$release_archive"
