#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
source conf/ob.env

AUTO_INIT="${AUTO_INIT:-true}"

usage() {
  cat <<EOF
用法: ./run.sh [--no-init]

  --no-init   仅启动容器，不等待就绪、不执行 Oracle 租户初始化
  -h, --help  显示本帮助
EOF
}

for arg in "$@"; do
  case "$arg" in
    --no-init) AUTO_INIT=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $arg"; usage; exit 1 ;;
  esac
done

log() {
  echo "[$(date '+%F %T')] $*"
}

container_exists() {
  docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

container_running() {
  [ "$(docker container inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

ensure_volumes() {
  mkdir -p "$DATA_DIR" "$OBD_CONF_DIR"
  log "持久化目录已就绪：$PWD/$DATA_DIR、$PWD/$OBD_CONF_DIR"
}

ensure_image() {
  if docker image inspect "$OB_IMAGE" >/dev/null 2>&1; then
    log "本地已存在镜像：$OB_IMAGE"
    return 0
  fi
  log "本地未找到镜像 $OB_IMAGE，开始拉取（首次可能较慢）..."
  if ! docker pull "$OB_IMAGE"; then
    log "错误：镜像拉取失败。请检查网络，或修改 conf/ob.env 中的 OB_IMAGE。"
    exit 1
  fi
}

ensure_network() {
  if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    local subnet
    subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$DOCKER_NETWORK" 2>/dev/null || true)"
    if [ -n "$subnet" ] && [ "$subnet" != "$NETWORK_SUBNET" ]; then
      log "错误：网络 ${DOCKER_NETWORK} 已存在，子网为 ${subnet}，与配置 ${NETWORK_SUBNET} 不一致。"
      log "请修改 conf/ob.env 的 NETWORK_SUBNET，或执行：docker network rm ${DOCKER_NETWORK}"
      exit 1
    fi
    log "复用已有 Docker 网络 ${DOCKER_NETWORK}（${subnet:-未知子网}）"
  else
    log "创建 Docker 网络 ${DOCKER_NETWORK}（${NETWORK_SUBNET}）..."
    if ! docker network create --subnet "$NETWORK_SUBNET" "$DOCKER_NETWORK" >/dev/null; then
      log "错误：创建网络失败，子网 ${NETWORK_SUBNET} 可能与已有网络或宿主机路由冲突。"
      log "请修改 conf/ob.env 的 NETWORK_SUBNET 与 CONTAINER_IP 后重试。"
      exit 1
    fi
  fi
}

ensure_container() {
  if container_exists; then
    if container_running; then
      log "容器 ${CONTAINER_NAME} 已在运行，复用现有容器。"
    else
      log "容器 ${CONTAINER_NAME} 已存在但已停止，启动容器..."
      if ! docker start "$CONTAINER_NAME" >/dev/null; then
        log "错误：启动容器失败，请执行：docker logs ${CONTAINER_NAME}"
        exit 1
      fi
    fi
    return 0
  fi

  if [ ! -f "$TIMEZONE_FILE" ]; then
    log "错误：找不到时区文件 ${TIMEZONE_FILE}，请修改 conf/ob.env 的 TIMEZONE_FILE。"
    exit 1
  fi

  if docker network inspect -f '{{json .Containers}}' "$DOCKER_NETWORK" 2>/dev/null \
      | grep -q "\"IPv4Address\":\"${CONTAINER_IP}/"; then
    log "错误：固定 IP ${CONTAINER_IP} 已被网络 ${DOCKER_NETWORK} 中的其他容器占用。"
    log "请修改 conf/ob.env 中的 CONTAINER_IP。"
    exit 1
  fi

  log "创建并启动容器 ${CONTAINER_NAME}..."
  if ! docker run -d \
      --name "$CONTAINER_NAME" \
      --network "$DOCKER_NETWORK" \
      --ip "$CONTAINER_IP" \
      -p "${HOST_PORT}:2881" \
      -e TZ="$TZ" \
      -e MODE="$MODE" \
      -e OB_CLUSTER_NAME="$OB_CLUSTER_NAME" \
      -e OB_MEMORY_LIMIT="$OB_MEMORY_LIMIT" \
      -e OB_SYSTEM_MEMORY="$OB_SYSTEM_MEMORY" \
      -e OB_DATAFILE_SIZE="$OB_DATAFILE_SIZE" \
      -e OB_LOG_DISK_SIZE="$OB_LOG_DISK_SIZE" \
      -e OB_SYS_PASSWORD="$OB_SYS_PASSWORD" \
      -e OB_TENANT_NAME="$OB_TENANT_NAME" \
      -e OB_TENANT_MIN_CPU="$OB_TENANT_MIN_CPU" \
      -e OB_TENANT_MEMORY_SIZE="$OB_TENANT_MEMORY_SIZE" \
      -e OB_TENANT_LOG_DISK_SIZE="$OB_TENANT_LOG_DISK_SIZE" \
      -v "$TIMEZONE_FILE:/etc/localtime:ro" \
      -v "$PWD/$DATA_DIR:/root/ob" \
      -v "$PWD/$OBD_CONF_DIR:/root/.obd/cluster" \
      "$OB_IMAGE" >/dev/null; then
    log "错误：容器创建失败。"
    log "若提示 Address already in use，请修改 conf/ob.env 中的 CONTAINER_IP。"
    log "若提示 Pool overlaps，请修改 NETWORK_SUBNET 或删除旧网络。"
    log "如有残留容器，可执行：docker rm -f ${CONTAINER_NAME} 后重试。"
    exit 1
  fi
  log "容器 ${CONTAINER_NAME} 已创建并启动。"
}

wait_for_boot() {
  log "等待 OceanBase 启动（最长 ${BOOT_TIMEOUT} 秒）..."
  local waited=0 last
  while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
    if ! container_running; then
      log "错误：容器未运行。最近日志："
      docker logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
      exit 1
    fi
    last="$(docker logs --tail 1 "$CONTAINER_NAME" 2>&1 || true)"
    case "$last" in
      *"boot success!"*)
        log "OceanBase 启动完成。"
        return 0
        ;;
      *"boot failed!"*)
        log "错误：OceanBase 启动失败。最近日志："
        docker logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
        exit 1
        ;;
    esac
    sleep 5
    waited=$((waited + 5))
  done
  log "错误：等待启动超时（${BOOT_TIMEOUT} 秒）。最近日志："
  docker logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
  exit 1
}

wait_for_sys() {
  log "等待 sys 租户可连接..."
  local i
  for i in $(seq 1 60); do
    if docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
        -uroot@sys -p"$OB_SYS_PASSWORD" -A -Doceanbase \
        -e "SELECT 1;" >/dev/null 2>&1; then
      log "sys 租户可连接。"
      return 0
    fi
    sleep 2
  done
  log "错误：sys 租户无法连接，请执行 ./log.sh 查看容器日志。"
  exit 1
}

ob_sys() {
  docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
    -uroot@sys -p"$OB_SYS_PASSWORD" -A -Doceanbase "$@"
}

query_sys() {
  ob_sys -s -N -e "$1" 2>/dev/null | tr -d ' \r\n'
}

render_sql() {
  sed \
    -e "s|@ZONE@|${ZONE}|g" \
    -e "s|@ORA_UNIT@|${ORA_UNIT}|g" \
    -e "s|@ORA_CPU@|${ORA_CPU}|g" \
    -e "s|@ORA_MEMORY@|${ORA_MEMORY}|g" \
    -e "s|@ORA_LOG_DISK@|${ORA_LOG_DISK}|g" \
    -e "s|@ORA_POOL@|${ORA_POOL}|g" \
    -e "s|@ORA_TENANT@|${ORA_TENANT}|g" \
    -e "s|@ORA_SYS_PASSWORD@|${ORA_SYS_PASSWORD}|g" \
    -e "s|@APP_USER@|${APP_USER}|g" \
    -e "s|@APP_PASSWORD@|${APP_PASSWORD}|g" \
    "$1"
}

exec_sql_sys() {
  render_sql "$1" | docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
    -uroot@sys -p"$OB_SYS_PASSWORD" -A -Doceanbase >/dev/null
}

exec_sql_oracle_sys() {
  render_sql "$1" | docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
    -usys@"$ORA_TENANT" -p"$ORA_SYS_PASSWORD" -A >/dev/null
}

exec_sql_oracle_sys_no_password() {
  render_sql "$1" | docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
    -usys@"$ORA_TENANT" -A >/dev/null
}

exec_sql_oracle_app() {
  render_sql "$1" | docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
    -u"$APP_USER"@"$ORA_TENANT" -p"$APP_PASSWORD" -A >/dev/null
}

query_oracle_sys() {
  docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
    -usys@"$ORA_TENANT" -p"$ORA_SYS_PASSWORD" -A -s -N -e "$1" 2>/dev/null | tr -d ' \r\n'
}

query_oracle_app() {
  docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
    -u"$APP_USER"@"$ORA_TENANT" -p"$APP_PASSWORD" -A -s -N -e "$1" 2>/dev/null | tr -d ' \r\n'
}

init_cluster_timezone() {
  log "设置数据库时区为 +08:00..."
  if ! ob_sys -e "ALTER SYSTEM SET time_zone = '+08:00';" >/dev/null 2>&1; then
    log "警告：数据库时区设置失败，继续执行。"
  fi
}

get_zone() {
  local zone
  zone="$(query_sys "SELECT ZONE FROM oceanbase.DBA_OB_ZONES LIMIT 1;")"
  if [ -z "$zone" ]; then
    log "错误：无法从 oceanbase.DBA_OB_ZONES 获取 zone。"
    exit 1
  fi
  echo "$zone"
}

wait_tenant_normal() {
  log "等待租户 ${ORA_TENANT} 就绪..."
  local i status
  for i in $(seq 1 150); do
    status="$(query_sys "SELECT STATUS FROM oceanbase.DBA_OB_TENANTS WHERE TENANT_NAME='${ORA_TENANT}';")"
    if [ "$status" = "NORMAL" ]; then
      log "租户 ${ORA_TENANT} 状态为 NORMAL。"
      return 0
    fi
    sleep 2
  done
  log "错误：等待租户 ${ORA_TENANT} 就绪超时，当前状态：${status:-未知}"
  exit 1
}

init_oracle_tenant() {
  ZONE="$(get_zone)"
  log "使用 zone：${ZONE}"

  local cnt

  cnt="$(query_sys "SELECT COUNT(*) FROM oceanbase.DBA_OB_UNIT_CONFIGS WHERE NAME='${ORA_UNIT}';")"
  if [ "${cnt:-0}" = "0" ]; then
    log "创建资源单元 ${ORA_UNIT}..."
    exec_sql_sys sql/01_create_unit.sql
  else
    log "资源单元 ${ORA_UNIT} 已存在，跳过。"
  fi

  cnt="$(query_sys "SELECT COUNT(*) FROM oceanbase.DBA_OB_RESOURCE_POOLS WHERE NAME='${ORA_POOL}';")"
  if [ "${cnt:-0}" = "0" ]; then
    log "创建资源池 ${ORA_POOL}..."
    exec_sql_sys sql/02_create_pool.sql
  else
    log "资源池 ${ORA_POOL} 已存在，跳过。"
  fi

  cnt="$(query_sys "SELECT COUNT(*) FROM oceanbase.DBA_OB_TENANTS WHERE TENANT_NAME='${ORA_TENANT}';")"
  if [ "${cnt:-0}" = "0" ]; then
    log "创建 Oracle 模式租户 ${ORA_TENANT}..."
    exec_sql_sys sql/03_create_tenant.sql
  else
    log "租户 ${ORA_TENANT} 已存在，跳过创建。"
  fi

  wait_tenant_normal
}

init_oracle_accounts() {
  local i cnt
  log "等待 Oracle 租户 sys 用户可连接..."
  for i in $(seq 1 60); do
    if docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
        -usys@"$ORA_TENANT" -p"$ORA_SYS_PASSWORD" -A \
        -e "SELECT 1 FROM DUAL;" >/dev/null 2>&1; then
      log "sys 用户可连接（密码已设置）。"
      break
    fi
    if docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
        -usys@"$ORA_TENANT" -A \
        -e "SELECT 1 FROM DUAL;" >/dev/null 2>&1; then
      log "sys 用户可连接（初始空密码）。"
      break
    fi
    if [ "$i" -eq 60 ]; then
      log "错误：Oracle 租户 sys 用户无法连接。"
      exit 1
    fi
    sleep 2
  done

  if docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
      -usys@"$ORA_TENANT" -p"$ORA_SYS_PASSWORD" -A \
      -e "SELECT 1 FROM DUAL;" >/dev/null 2>&1; then
    log "Oracle 租户 sys 密码已正确，跳过改密。"
  else
    log "设置 Oracle 租户 sys 密码..."
    exec_sql_oracle_sys_no_password sql/04_alter_oracle_sys_password.sql
    if ! docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
        -usys@"$ORA_TENANT" -p"$ORA_SYS_PASSWORD" -A \
        -e "SELECT 1 FROM DUAL;" >/dev/null 2>&1; then
      log "错误：修改 sys 密码后仍无法连接。"
      exit 1
    fi
  fi

  cnt="$(query_oracle_sys "SELECT COUNT(*) FROM DBA_USERS WHERE USERNAME = UPPER('${APP_USER}');")"
  if [ "${cnt:-0}" = "0" ]; then
    log "创建业务用户 ${APP_USER}..."
    exec_sql_oracle_sys sql/05_create_app_user.sql
  else
    log "业务用户 ${APP_USER} 已存在，跳过创建。"
  fi

  log "授予 ${APP_USER} CONNECT / RESOURCE / DBA 权限..."
  docker exec -i "$CONTAINER_NAME" obclient -h127.0.0.1 -P2881 \
    -usys@"$ORA_TENANT" -p"$ORA_SYS_PASSWORD" -A \
    -e "GRANT CONNECT, RESOURCE, DBA TO ${APP_USER};" >/dev/null

  cnt="$(query_oracle_app "SELECT COUNT(*) FROM USER_TABLES WHERE TABLE_NAME = 'EMP';")"
  if [ "${cnt:-0}" = "0" ]; then
    log "初始化示例表 EMP..."
    exec_sql_oracle_app sql/06_init_emp_schema.sql
  else
    log "示例表 EMP 已存在，跳过初始化。"
  fi
}

print_connection_info() {
  local container_date
  container_date="$(docker exec "$CONTAINER_NAME" date '+%F %T %Z (%z)' 2>/dev/null || echo '未知')"

  echo
  log "初始化完成。"
  echo
  echo "请使用 宿主机IP + 端口 ${HOST_PORT} 访问（容器内部 IP 仅用于 obd 自恢复）："
  echo
  echo "  sys 租户："
  echo "    obclient -h<HOST_IP> -P${HOST_PORT} -uroot@sys -p${OB_SYS_PASSWORD} -Doceanbase -A"
  echo
  echo "  Oracle 租户管理员："
  echo "    obclient -h<HOST_IP> -P${HOST_PORT} -usys@${ORA_TENANT} -p${ORA_SYS_PASSWORD} -A"
  echo
  echo "  Oracle 业务用户："
  echo "    obclient -h<HOST_IP> -P${HOST_PORT} -u${APP_USER}@${ORA_TENANT} -p${APP_PASSWORD} -A"
  echo
  echo "  容器时间：${container_date}"
  echo
  echo "执行 ./test.sh 可自动验证数据库状态。"
}

ensure_volumes
ensure_image
ensure_network
ensure_container

if [ "$AUTO_INIT" != "true" ]; then
  log "已指定 --no-init，跳过等待与初始化。容器在后台继续启动，稍后可执行 ./test.sh 验证。"
  exit 0
fi

wait_for_boot
wait_for_sys
init_cluster_timezone
init_oracle_tenant
init_oracle_accounts
print_connection_info
