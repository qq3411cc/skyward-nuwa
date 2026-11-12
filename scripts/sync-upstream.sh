#!/bin/sh
# 上游 kirklin/skyward 出了新 tag 时，把本仓库的补丁链带过去，试一遍能不能编。
#
# 用法（在仓库根目录跑）：
#   scripts/sync-upstream.sh                 # 查上游最新，与本仓库钉的比
#   scripts/sync-upstream.sh v0.3.0          # 指定 tag
#   scripts/sync-upstream.sh v0.3.0 --write  # 打得进去就改 upstream.json
#
# 只做本地这一步：查版本、下源码、试打补丁、报冲突。真正出包交给 GitHub Actions
# （.github/workflows/build.yml），发布流程见 sync-upstream.yml。
set -eu

REPO=kirklin/skyward
PUDDING_URL=https://raw.githubusercontent.com/mariusarva/skyward-pudding/9ab25b7802466e1fae0decb1b4d3f133540be1c3/patches/skyward-pudding-v0.2.41.patch
PUDDING_SHA=12e6d543dc23b60a7478211fe000cd3e8f487fbcb3bea460618beb501b534f0c

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

TAG="${1:-}"
WRITE=no
[ "${2:-}" = "--write" ] && WRITE=yes

PINNED=$(sed -n 's/.*"tag": *"\([^"]*\)".*/\1/p' upstream.json)
[ -n "$TAG" ] || TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/tags?per_page=100" \
  | sed -n 's/.*"name": *"\(v[0-9][0-9.]*\)".*/\1/p' | sort -V | tail -1)
[ -n "$TAG" ] || { echo "查不到上游 tag" >&2; exit 1; }

echo "钉的：$PINNED    要试：$TAG"
[ "$PINNED" = "$TAG" ] && { echo "已经是最新，没什么要做的"; exit 0; }

WORK="$ROOT/build/sync-$TAG"
rm -rf "$WORK"; mkdir -p "$WORK"
echo "== 1/3 取上游 $TAG"
curl -fL --retry 3 -o "$WORK/upstream.tar.gz" "https://codeload.github.com/$REPO/tar.gz/refs/tags/$TAG"
SHA=$(sha256sum "$WORK/upstream.tar.gz" | cut -d' ' -f1)
mkdir -p "$WORK/src"
tar xzf "$WORK/upstream.tar.gz" -C "$WORK/src" --strip-components=1

echo "== 2/3 取补丁"
curl -fL --retry 3 -o "$WORK/pudding.patch" "$PUDDING_URL"
echo "$PUDDING_SHA  $WORK/pudding.patch" | sha256sum -c -

echo "== 3/3 试打"
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
       <该 tag 的干净源码> $WORK/src > patches/skyward-nuwa-extra.patch
  3. 改 upstream.json 的 tag 与 tarball_sha256（本次源码包 sha256 = $SHA）
  4. 推 main，构建流程自己出包
EOF
  exit 1
fi

echo
echo "补丁链原样打得进去。源码包 sha256 = $SHA"
if [ "$WRITE" = yes ]; then
  sed -i "s/\"tag\": *\"[^\"]*\"/\"tag\": \"$TAG\"/; s/\"tarball_sha256\": *\"[^\"]*\"/\"tarball_sha256\": \"$SHA\"/" upstream.json
  echo "upstream.json 已更新，接着：git add upstream.json && git commit -m 'sync: 上游 $TAG' && git push"
else
  echo "要写进 upstream.json 就加 --write"
fi
