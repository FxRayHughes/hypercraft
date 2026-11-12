#!/usr/bin/env bash
# Hypercraft 1Panel 发布脚本：同步源码到构建机 → 构建 API/Web 镜像 → 推送 Nexus → 更新 1Panel 本地应用包
#
# 用法（仓库根目录执行）：
#   deploy/1panel/release.sh 0.1.1          # 构建并发布 0.1.1
#   deploy/1panel/release.sh 0.1.1 --skip-build   # 仅更新应用包
#
# 前置：~/.ssh/config 中已有 Host mc-dev；构建机 /root/.nexus_deployer 存有 deployer 密码。
# 新版本应用包：复制 deploy/1panel/hypercraft/<旧版本> 为 <新版本>，并改其中 docker-compose.yml 的镜像 tag。
set -euo pipefail

VERSION="${1:?usage: release.sh <version> [--skip-build]}"
SKIP_BUILD="${2:-}"
HOST="${HC_BUILD_HOST:-mc-dev}"
REMOTE_SRC=/data/build/hypercraft
PUSH_REG=127.0.0.1:8082/hypercraft
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/deploy/1panel/hypercraft"

[ -d "${PKG}/${VERSION}" ] || { echo "缺少应用包版本目录 ${PKG}/${VERSION}" >&2; exit 1; }
grep -q "hypercraft-api:${VERSION}" "${PKG}/${VERSION}/docker-compose.yml" || { echo "${VERSION}/docker-compose.yml 中镜像 tag 与版本不一致" >&2; exit 1; }

if [ "$SKIP_BUILD" != "--skip-build" ]; then
  echo "==> 同步源码到 ${HOST}:${REMOTE_SRC}"
  ssh "${HOST}" "mkdir -p ${REMOTE_SRC} /data/build/logs"
  rsync -az --delete \
    --exclude .git --exclude 'target/' --exclude 'node_modules/' --exclude '.next/' \
    --exclude '/data/' --exclude '/services/' --exclude '/.env' --exclude '/icon.af' --exclude '/images/' --exclude '/deploy/' \
    "$ROOT/" "${HOST}:${REMOTE_SRC}/"

  echo "==> 构建镜像 ${VERSION}（并行）"
  ssh "${HOST}" bash -s -- "${VERSION}" "${PUSH_REG}" <<'EOS'
set -euo pipefail
V="$1"; R="$2"; cd /data/build/hypercraft
docker build -f docker/Dockerfile.api --build-arg CARGO_MIRROR=sparse+https://rsproxy.cn/index/ --build-arg GITHUB_PROXY=https://ghfast.top/ -t "$R/hypercraft-api:$V" . > /data/build/logs/api.log 2>&1 & A=$!
docker build -f docker/Dockerfile.web --build-arg NPM_REGISTRY=https://registry.npmmirror.com -t "$R/hypercraft-web:$V" . > /data/build/logs/web.log 2>&1 & W=$!
wait $A || { tail -30 /data/build/logs/api.log; exit 1; }
wait $W || { tail -30 /data/build/logs/web.log; exit 1; }
cat /root/.nexus_deployer | docker login 127.0.0.1:8082 -u deployer --password-stdin >/dev/null
for n in api web; do
  docker tag "$R/hypercraft-$n:$V" "$R/hypercraft-$n:latest"
  docker push -q "$R/hypercraft-$n:$V"; docker push -q "$R/hypercraft-$n:latest"
done
docker logout 127.0.0.1:8082 >/dev/null; rm -f /root/.docker/config.json
EOS
fi

echo "==> 更新 1Panel 本地应用包"
python3 "$HOME/.agents/skills/1Panel-appstore-skills/scripts/validate_app_package.py" "${PKG}" || true
rsync -a --delete "${PKG}/" "${HOST}:/opt/1panel/resource/apps/local/hypercraft/"
ssh "${HOST}" '/root/1p.sh POST /apps/sync/local "{}" >/dev/null && echo "1Panel 本地应用已同步"'
echo "完成：在 1Panel → 应用商店 → 已安装 中可升级到 ${VERSION}"
