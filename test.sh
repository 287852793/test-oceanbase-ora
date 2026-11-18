#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
source conf/ob.env

fail() {
  echo "[失败] $*" >&2
  exit 1
}

info() {
  echo "[检查] $*"
}

if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  fail "容器 ${CONTAINER_NAME} 不存在，请先执行 ./run.sh"
fi

if [ "$(docker container inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
  fail "容器 ${CONTAINER_NAME} 未运行，请先执行 ./run.sh"
fi

info "检查容器时区..."
tz_line="$(docker exec "$CONTAINER_NAME" date '+%F %T %Z (%z)' 2>/dev/null || true)"
tzo="$(docker exec "$CONTAINER_NAME" date '+%z' 2>/dev/null || true)"
echo "  容器时间: ${tz_line:-未知}"
if [ "$tzo" != "+0800" ]; then
  fail "容器时区不是 +0800（Asia/Shanghai），请检查 run.sh 的时区配置。"
fi

info "检查 Oracle 租户兼容模式..."
mode="$(docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
  -uroot@sys -p"$OB_SYS_PASSWORD" -A -Doceanbase -s -N \
  -e "SELECT COMPATIBILITY_MODE FROM oceanbase.DBA_OB_TENANTS WHERE TENANT_NAME='${ORA_TENANT}';" \
  2>/dev/null | tr -d ' \r\n')"
echo "  ${ORA_TENANT} COMPATIBILITY_MODE=${mode:-<空>}"
if [ "$mode" != "ORACLE" ]; then
  fail "租户 ${ORA_TENANT} 不是 Oracle 兼容模式，请先执行 ./run.sh 完成初始化。"
fi

info "检查 Oracle 业务用户..."
docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
  -u"$APP_USER"@"$ORA_TENANT" -p"$APP_PASSWORD" -A \
  -e "SELECT 'OK' AS RESULT FROM DUAL;" 2>/dev/null || fail "业务用户 ${APP_USER} 无法连接。"

cnt="$(docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
  -u"$APP_USER"@"$ORA_TENANT" -p"$APP_PASSWORD" -A -s -N \
  -e "SELECT COUNT(*) FROM EMP;" 2>/dev/null | tr -d ' \r\n')"
echo "  EMP 行数: ${cnt:-<空>}"
if [ "${cnt:-}" != "3" ]; then
  fail "示例表 EMP 数据不符合预期（期望 3 行，实际 ${cnt:-空}）。"
fi

echo
echo "全部检查通过。"
