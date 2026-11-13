#!/bin/sh
# 上游（mariusarva/skyward-pudding）出了新补丁时，把本仓库的补丁链带过去试一遍。
#
# 用法（在仓库根目录跑）：
#   scripts/sync-upstream.sh                       # 查上游最新补丁，与钉的比
#   scripts/sync-upstream.sh v0.2.52               # 指定补丁版本
#   scripts/sync-upstream.sh v0.2.52 --write       # 打得进去就写回 upstream.json
#
# 只做本地这一步：查版本、下源码与补丁、试打、报冲突。出包交给 GitHub Actions。
set -eu

FORK=mariusarva/skyward-pudding
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

WANT="${1:-}"
WRITE=no
[ "${2:-}" = "--write" ] && WRITE=yes

PINNED=$(sed -n 's/.*"path": *"\([^"]*\)".*/\1/p' upstream.json | head -1)
BASE_REPO=$(sed -n 's/.*"repository": *"\([^"]*\)".*/\1/p' upstream.json | head -1)
BASE_TAG=$(sed -n 's/.*"tag": *"\([^"]*\)".*/\1/p' upstream.json | head -1)
BASE_SHA=$(sed -n 's/.*"tarball_sha256": *"\([^"]*\)".*/\1/p' upstream.json | head -1)

if [ -n "$WANT" ]; then
  case "$WANT" in */*) NEW="$WANT" ;; *) NEW="patches/skyward-pudding-$WANT.patch" ;; esac
else
  NEW=$(curl -fsSL "https://api.github.com/repos/$FORK/contents/patches" \
    | sed -n 's/.*"name": *"\(skyward-pudding-v[0-9][0-9.]*\.patch\)".*/\1/p' | sort -V | tail -1)
  NEW="patches/$NEW"
fi
[ -n "$NEW" ] || { echo "查不到上游补丁" >&2; exit 1; }

echo "钉的：$PINNED"
echo "要试：$NEW"
[ "$PINNED" = "$NEW" ] && { echo "已经是最新，没什么要做的"; exit 0; }

COMMIT=$(curl -fsSL "https://api.github.com/repos/$FORK/commits?per_page=1" \
  | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
[ -n "$COMMIT" ] || { echo "查不到上游提交" >&2; exit 1; }
echo "上游提交：$COMMIT"

WORK="$ROOT/build/sync"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "== 1/4 取上游源码 $BASE_TAG"
URL="https://codeload.github.com/$BASE_REPO/tar.gz/refs/tags/$BASE_TAG"
if ! curl -fL --retry 1 --max-time 90 -o "$WORK/upstream.tar.gz" "$URL"; then
  echo "   直连太慢，改走 gh-proxy"
  rm -f "$WORK/upstream.tar.gz"
  curl -fL --retry 3 -o "$WORK/upstream.tar.gz" "https://gh-proxy.com/$URL"
fi
[ -n "$BASE_SHA" ] && { echo "$BASE_SHA  $WORK/upstream.tar.gz" | sha256sum -c -; }
mkdir -p "$WORK/src"
tar xzf "$WORK/upstream.tar.gz" -C "$WORK/src" --strip-components=1

echo "== 2/4 取上游补丁 $NEW"
if ! curl -fL --retry 1 --max-time 60 -o "$WORK/pudding.patch" \
     "https://raw.githubusercontent.com/$FORK/$COMMIT/$NEW"; then
  curl -fL --retry 3 -o "$WORK/pudding.patch" "https://gh-proxy.com/https://raw.githubusercontent.com/$FORK/$COMMIT/$NEW"
fi
PSHA=$(sha256sum "$WORK/pudding.patch" | cut -d' ' -f1)

echo "== 3/4 试打"
cd "$WORK/src"
FAILED=0
for P in "$WORK/pudding.patch" "$ROOT/patches/skyward-nuwa-extra.patch"; do
  echo "-- $(basename "$P")"
  if patch -p1 --batch --dry-run --no-backup-if-mismatch < "$P" > "$WORK/dry.log" 2>&1; then
    patch -p1 --batch --no-backup-if-mismatch < "$P" > /dev/null
    echo "   打得进去"
  else
    echo "   打不进去："
    grep -E 'FAILED|Hunk' "$WORK/dry.log" | head -40
    FAILED=1
  fi
done

if [ "$FAILED" != "0" ]; then
  cat <<EOF

有冲突。手工合的办法：
  1. 在 $WORK/src 里按冲突改，或按 README「从源码重建」一步步来
  2. 合完重出补丁：diff -ruN --exclude=target --exclude=.git \\
       <上游源码的干净树> $WORK/src > patches/skyward-nuwa-extra.patch
  3. 改 upstream.json 的 patches.commit / patches.path / patches.sha256
     （本次补丁 sha256 = $PSHA）
  4. 推 main，构建流程自己出包
EOF
  exit 1
fi

echo
echo "补丁链原样打得进去。补丁 sha256 = $PSHA"
if [ "$WRITE" = yes ]; then
  python3 - "$COMMIT" "$NEW" "$PSHA" <<'PY'
import json, sys
commit, path, sha = sys.argv[1:4]
d = json.load(open("upstream.json"))
d["patches"]["commit"] = commit
d["patches"]["path"] = path
d["patches"]["sha256"] = sha
open("upstream.json", "w").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY
  echo "upstream.json 已更新，接着：git add upstream.json && git commit -m 'sync: $NEW' && git push"
else
  echo "要写进 upstream.json 就加 --write"
fi
