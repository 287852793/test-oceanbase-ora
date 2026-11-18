#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
source conf/ob.env

PURGE=false

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=true ;;
    -h|--help)
      cat <<EOF
用法: ./stop.sh [--purge]

  默认仅停止容器，保留容器与 volumes 数据，下次 ./run.sh 会直接复用。
  --purge  停止并删除容器（volumes 数据仍保留）
EOF
      exit 0
      ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "容器 ${CONTAINER_NAME} 不存在，无需停止。"
  exit 0
fi

echo "停止容器 ${CONTAINER_NAME}..."
docker stop "$CONTAINER_NAME" >/dev/null || true

if [ "$PURGE" = "true" ]; then
  echo "删除容器 ${CONTAINER_NAME}..."
  docker rm "$CONTAINER_NAME" >/dev/null || true
fi

echo "完成。volumes 目录中的数据已保留。"
