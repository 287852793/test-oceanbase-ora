#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
source conf/ob.env

if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "容器 ${CONTAINER_NAME} 不存在，请先执行 ./run.sh"
  exit 1
fi

docker logs -f --tail 200 "$CONTAINER_NAME"
