#!/usr/bin/env bash
# sync-www.sh — 把前端构建产物 dist/ 同步进 HAP 壳工程，并执行完整性校验。
#
# 用法（仓库根目录）:
#   npm ci && npm run build && ./harmony/sync-www.sh
#
# 仅支持 macOS（使用 shasum、stat -f，以及 BSD find/sort/xargs 的零字节分隔符）。
set -euo pipefail

# 仓库根 = 脚本目录的上一级
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DIST_DIR="${REPO_ROOT}/dist"
ICON_SRC="${REPO_ROOT}/public/icon-512.png"
WWW_DIR="${SCRIPT_DIR}/entry/src/main/resources/rawfile/www"
APP_ICON_DST="${SCRIPT_DIR}/AppScope/resources/base/media/app_icon.png"
ENTRY_ICON_DST="${SCRIPT_DIR}/entry/src/main/resources/base/media/icon.png"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[ -f "${DIST_DIR}/index.html" ] || fail "未找到 ${DIST_DIR}/index.html，请先在仓库根执行 npm ci && npm run build"
[ -f "${ICON_SRC}" ] || fail "未找到 ${ICON_SRC}"

echo "==> 1/4 同步 dist/ -> entry/src/main/resources/rawfile/www/（剔除 sw.js / .DS_Store）"
mkdir -p "${WWW_DIR}"
rsync -a --delete \
  --exclude 'sw.js' \
  --exclude '.DS_Store' \
  "${DIST_DIR}/" "${WWW_DIR}/"
# rsync 的 --exclude 默认同时保护目标端同名文件不被 --delete 删除，这里显式剔除兜底
rm -f "${WWW_DIR}/sw.js" "${WWW_DIR}/.DS_Store"

echo "==> 2/4 拷贝应用图标（public/icon-512.png）"
mkdir -p "$(dirname "${APP_ICON_DST}")" "$(dirname "${ENTRY_ICON_DST}")"
cp "${ICON_SRC}" "${APP_ICON_DST}"
cp "${ICON_SRC}" "${ENTRY_ICON_DST}"

echo "==> 3/4 生成 shasum 清单并比对"
# 对两个目录分别生成 "<sha>  ./相对路径" 清单（均排除 sw.js / .DS_Store）。
# -print0 / sort -z / xargs -0 与 Spec 的 find | sort | xargs shasum 语义一致，
# 但保证含空格的文件名不会被拆散。
manifest_of() {
  (cd "$1" && find . -type f ! -name 'sw.js' ! -name '.DS_Store' -print0 | sort -z | xargs -0 shasum)
}
DIST_MANIFEST="$(manifest_of "${DIST_DIR}")"
WWW_MANIFEST="$(manifest_of "${WWW_DIR}")"

if [ "${DIST_MANIFEST}" != "${WWW_MANIFEST}" ]; then
  echo "MISMATCH: dist/（排除 sw.js/.DS_Store）与 rawfile/www/ 清单不一致，中止" >&2
  diff <(printf '%s\n' "${DIST_MANIFEST}") <(printf '%s\n' "${WWW_MANIFEST}") | head -40 >&2 || true
  exit 1
fi

echo "==> 4/4 完整性校验通过"
FILE_COUNT="$(cd "${WWW_DIR}" && find . -type f ! -name 'sw.js' ! -name '.DS_Store' | wc -l | tr -d ' ')"
TOTAL_BYTES="$(cd "${WWW_DIR}" && find . -type f ! -name 'sw.js' ! -name '.DS_Store' -exec stat -f%z {} + | awk '{ s += $1 } END { print s + 0 }')"
echo "OK: rawfile/www/ 与 dist/ 逐字节一致，共 ${FILE_COUNT} 个文件，${TOTAL_BYTES} 字节"
