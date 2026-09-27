#!/usr/bin/env bash
# =============================================================================
#  ops.sh —— mall 项目构建 & 镜像操作
#
#  对应目录结构（每个模块一个 dockerfile）:
#     mall-admin/dockerfile
#     mall-search/dockerfile
#     mall-portal/dockerfile
#     mall-demo/dockerfile
#
#  用法:
#     ./ops.sh build <module>...     用 Maven 构建
#     ./ops.sh image <module>...     构建 Docker 镜像（配了 REGISTRY 就推送）
#     ./ops.sh help
#
#  示例:
#     ./ops.sh build all
#     ./ops.sh build mall-admin
#     ./ops.sh image mall-admin
#     ./ops.sh image all
#     REGISTRY= ./ops.sh image all              # 只构建，不推送
#
#  镜像 tag = git commit id 前 7 位；工作区脏时加 -dirty 后缀。
#
#  环境变量:
#     REGISTRY      镜像仓库前缀  默认 192.168.203.120/library（置空则只构建不推送）
#     IMAGE_TAG     手动指定 tag（默认自动取 commit id）
#     GIT_SHA_LEN   commit id 取几位，默认 7
#     DIRTY_SUFFIX  工作区脏时是否加 -dirty，默认 1；设 0 关闭
#     MVN_OPTS      额外 maven 参数
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"          # 切到脚本所在目录（即仓库根目录）

REGISTRY="${REGISTRY-192.168.203.120:80/mall}"
IMAGE_TAG="${IMAGE_TAG-}"                       # 留空 = 自动用 commit id
APP_VERSION="${APP_VERSION:-1.0-SNAPSHOT}"
GIT_SHA_LEN="${GIT_SHA_LEN:-7}"                 # 7 位
DIRTY_SUFFIX="${DIRTY_SUFFIX:-1}"
MVN_OPTS="${MVN_OPTS:-}"

ALL_MODULES="mall-admin mall-search mall-portal mall-demo"

#--------------------------------------------------------------- 工具函数 ----
info() { echo "▶ $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
ops.sh —— mall 项目构建 & 镜像操作

用法:
  ./ops.sh build <module>...     用 Maven 构建
  ./ops.sh image <module>...     构建 Docker 镜像（配了 REGISTRY 就推送）
  ./ops.sh help                  显示帮助

模块（可写多个，或写 all）:
  mall-admin   mall-search   mall-portal   mall-demo

镜像命名:
  默认 tag = git commit id 前 7 位，例如 mall-admin:a37eb87
  工作区有未提交改动时加 -dirty，例如 mall-admin:a37eb87-dirty

环境变量:
  REGISTRY      镜像仓库前缀   默认 192.168.203.120/library
                               置空则只构建不推送:  REGISTRY= ./ops.sh image all
  IMAGE_TAG     手动指定 tag（默认自动取 commit id）
  GIT_SHA_LEN   commit id 取几位，默认 7
  DIRTY_SUFFIX  工作区脏时是否加 -dirty，默认 1；设 0 关闭
  MVN_OPTS      额外 maven 参数

示例:
  ./ops.sh build all
  ./ops.sh image mall-portal
  ./ops.sh image all
  IMAGE_TAG=v1 ./ops.sh image all           # 手动指定 tag
EOF
}

# 参数 -> 模块列表（校验合法性）
resolve_modules() {
  if [ "$#" -eq 1 ] && [ "$1" = "all" ]; then
    echo "$ALL_MODULES"
    return 0
  fi
  local m
  for m in "$@"; do
    case " $ALL_MODULES " in
      *" $m "*) ;;
      *) die "未知模块: $m
   可选: $ALL_MODULES | all" ;;
    esac
  done
  echo "$@"
}

# 找模块的 dockerfile（大小写都认）
dockerfile_of() {
  local m="$1"
  if   [ -f "$m/Dockerfile" ]; then echo "$m/Dockerfile"
  elif [ -f "$m/dockerfile" ]; then echo "$m/dockerfile"
  else return 1
  fi
}

# 镜像 tag：优先 IMAGE_TAG，否则取 git commit id 前 N 位
resolve_tag() {
  if [ -n "$IMAGE_TAG" ]; then
    printf '%s' "$IMAGE_TAG"
    return 0
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "⚠  不是 git 仓库，镜像 tag 回退为 $APP_VERSION" >&2
    printf '%s' "$APP_VERSION"
    return 0
  fi

  local sha dirty
  sha="$(git rev-parse --short="$GIT_SHA_LEN" HEAD)"
  dirty="$(git status --porcelain 2>/dev/null || true)"

  if [ -n "$dirty" ] && [ "$DIRTY_SUFFIX" = "1" ]; then
    {
      echo "⚠  工作区有未提交改动，镜像 tag 加 -dirty 后缀："
      echo "$dirty" | head -5 | sed 's/^/     /'
      echo "   设 DIRTY_SUFFIX=0 可忽略"
    } >&2
    sha="$sha-dirty"
  fi

  printf '%s' "$sha"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "找不到 docker 命令"
  if ! docker info >/dev/null 2>&1; then
    die "无法访问 Docker。请检查:
   1) 是否已加入 docker 组 —— 执行 newgrp docker 或重新登录
   2) docker 服务是否在跑 —— sudo systemctl status docker"
  fi
}

#----------------------------------------------------------------- build -----
cmd_build() {
  [ "$#" -ge 1 ] || die "缺少参数。用法: ./ops.sh build <module>|all"

  if [ "$#" -eq 1 ] && [ "$1" = "all" ]; then
    info "Maven 全量构建：mvn -B -DskipTests -Ddocker.skip=true clean package"
    mvn -B -DskipTests -Ddocker.skip=true $MVN_OPTS clean package
  else
    local mods m
    mods="$(resolve_modules "$@")"
    for m in $mods; do
      info "Maven 构建: $m（含它依赖的 mall-common/mall-mbg/mall-security，-am）"
      mvn -B -DskipTests -Ddocker.skip=true $MVN_OPTS -pl "$m" -am clean package
    done
  fi

  echo
  info "构建完成，产物："
  ls -1 */target/*.jar 2>/dev/null | sed 's/^/   /' || true
}

#----------------------------------------------------------------- image -----
cmd_image() {
  [ "$#" -ge 1 ] || die "缺少参数。用法: ./ops.sh image <module>|all"
  require_docker

  local mods m df jar tag local_image remote_image
  mods="$(resolve_modules "$@")"
  tag="$(resolve_tag)"

  echo "══════════════════════════════════════════════"
  info "镜像 tag : $tag"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    info "代码版本 : $(git log -1 --format='%h %s')"
  fi
  info "仓库前缀 : ${REGISTRY:-<空，不推送>}"
  echo "══════════════════════════════════════════════"

  for m in $mods; do
    jar="$m/target/$m-$APP_VERSION.jar"
    local_image="$m:$tag"
    df="$(dockerfile_of "$m")" || die "找不到 $m 的 dockerfile"

    echo "──────────────────────────────────────────────"
    [ -f "$jar" ] || die "找不到 jar: $jar
   先执行: ./ops.sh build $m"

    info "[$m] docker build -f $df $m/"
    docker build -t "$local_image" -f "$df" "$m/"

    if [ -n "$REGISTRY" ]; then
      remote_image="$REGISTRY/$m:$tag"

      info "[$m] docker tag  $local_image -> $remote_image"
      docker tag "$local_image" "$remote_image"

      info "[$m] docker push -> $remote_image"
      if ! docker push "$remote_image"; then
        cat >&2 <<EOF

❌ 推送失败。常见原因：
   1) Harbor 没起来        cd ~/harbor && docker compose up -d
   2) 没配 insecure-registries（Harbor 是 HTTP）
        /etc/docker/daemon.json 加: "insecure-registries": ["${REGISTRY%%/*}"]
        然后 sudo systemctl restart docker
   3) 没登录              docker login ${REGISTRY%%/*}
EOF
        exit 1
      fi
    else
      info "[$m] REGISTRY 为空 → 仅本地构建，跳过推送"
    fi
  done

  echo "──────────────────────────────────────────────"
  info "完成。当前镜像："
  docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep -E 'REPOSITORY|mall-' || true
}

#------------------------------------------------------------------ 入口 -----
cmd="${1:-}"
shift || true

case "$cmd" in
  build) cmd_build "$@" ;;
  image) cmd_image "$@" ;;
  help|-h|--help|"") usage ;;
  *) usage; die "未知命令: $cmd" ;;
esac
