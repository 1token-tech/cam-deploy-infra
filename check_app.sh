#!/bin/bash
# CAM application diagnostic script
# Collects deployment region, server basics, container status, and PG/Redis usage

set -u

RESULT_FILE="${RESULT_FILE:-./check_app_result_$(date +%Y%m%d_%H%M%S).txt}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.cam/config-prod.yml}"

if [[ -n "${HOME:-}" ]]; then
  CONFIG_FILE="${CONFIG_FILE/#\~/$HOME}"
fi

: >"$RESULT_FILE"

log() {
  printf '%s\n' "$*" | tee -a "$RESULT_FILE"
}

section() {
  log "================================================"
  log "$1"
  log "================================================"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

classify_host() {
  local host="$1"

  if [[ -z "$host" ]]; then
    echo "unknown"
    return
  fi

  case "$host" in
    127.0.0.1|localhost)
      echo "local"
      ;;
    *.rds.aliyuncs.com|*.redis.rds.aliyuncs.com|*.rds.amazonaws.com|*.cache.amazonaws.com|*.amazonaws.com|*.postgres.database.azure.com|*.redis.cache.windows.net|*.googleapis.com|*.cloudsql|*.aliyuncs.com)
      echo "cloud"
      ;;
    *)
      echo "remote"
      ;;
  esac
}

get_os_version() {
  if command_exists lsb_release; then
    lsb_release -ds 2>/dev/null
    return
  fi

  if [[ -f /etc/os-release ]]; then
    awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release
    return
  fi

  uname -a
}

get_cpu_cores() {
  if command_exists nproc; then
    nproc
    return
  fi

  if command_exists sysctl; then
    sysctl -n hw.ncpu 2>/dev/null
    return
  fi

  echo "unknown"
}

get_total_memory() {
  if command_exists free; then
    free -h | awk '/^Mem:/ {print $2}'
    return
  fi

  if command_exists sysctl; then
    local bytes
    bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
    if [[ -n "${bytes:-}" ]]; then
      awk -v bytes="$bytes" 'BEGIN {printf "%.1fGi\n", bytes / 1024 / 1024 / 1024}'
      return
    fi
  fi

  echo "unknown"
}

get_disk_info() {
  if command_exists lsblk; then
    lsblk
    return
  fi

  if command_exists df; then
    df -h
    return
  fi

  echo "disk information command not available"
}

print_public_ip_info() {
  if command_exists curl; then
    curl -fsS --max-time 5 ipinfo.io 2>/dev/null || echo "public ip lookup unavailable"
    return
  fi

  echo "curl command not available"
}

find_docker_daemon_conf() {
  local conf
  for conf in /etc/docker/daemon.json; do
    if [[ -r "$conf" ]]; then
      echo "$conf"
      return 0
    fi
  done
  return 1
}

extract_docker_log_opt() {
  local file="$1"
  local key="$2"

  if command_exists jq; then
    jq -r --arg k "$key" '."log-opts"[$k] // empty' "$file" 2>/dev/null || true
    return
  fi

  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" 2>/dev/null | head -n 1
}

extract_pg_summary() {
  local file="$1"

  awk '
    /^pg:/ {in_pg=1; next}
    in_pg && /^[^ ]/ {in_pg=0}
    in_pg && /^  default:/ {in_default=1; next}
    in_default && /^  [^ ]/ {in_default=0}
    in_default && /^    host:/ {sub(/^    host:[[:space:]]*/, "", $0); host=$0}
    in_default && /^    port:/ {sub(/^    port:[[:space:]]*/, "", $0); port=$0}
    in_default && /^    database:/ {sub(/^    database:[[:space:]]*/, "", $0); database=$0}
    END {
      if (host != "" || port != "" || database != "") {
        printf("host=%s\nport=%s\ndatabase=%s\n", host, port, database)
      }
    }
  ' "$file"
}

extract_redis_summary() {
  local file="$1"

  awk '
    /^redis:/ {in_redis=1; next}
    in_redis && /^[^ ]/ {in_redis=0}
    !in_redis {next}

    /^  [A-Za-z0-9._-]+:/ {
      if (name != "") {
        printf("%s|%s|%s|%s\n", name, host, port, db)
      }
      name=$0
      sub(/^  /, "", name)
      sub(/:$/, "", name)
      host=""
      port=""
      db=""
      next
    }

    /^    host:/ {sub(/^    host:[[:space:]]*/, "", $0); host=$0; next}
    /^    port:/ {sub(/^    port:[[:space:]]*/, "", $0); port=$0; next}
    /^    db:/ {sub(/^    db:[[:space:]]*/, "", $0); db=$0; next}

    END {
      if (name != "") {
        printf("%s|%s|%s|%s\n", name, host, port, db)
      }
    }
  ' "$file"
}

section "CAM Application Check"
log "Result file: $RESULT_FILE"
log ""

section "[1] Deployment Region"
log "Hostname: $(hostname 2>/dev/null || echo unknown)"
log "CAM_REGION: ${CAM_REGION:-not set}"
log "Public IP Information:"
print_public_ip_info | tee -a "$RESULT_FILE"
log ""

section "[2] Server Basics"
log "Current Time: $(date)"
log "Operating System: $(get_os_version)"
log "CPU Cores: $(get_cpu_cores)"
log "Total Memory: $(get_total_memory)"
log "Disk Information:"
get_disk_info | tee -a "$RESULT_FILE"
log ""

section "[3] Docker Containers"
if command_exists docker; then
  docker ps -a | tee -a "$RESULT_FILE"
else
  log "docker command is not available"
fi
log ""

section "[4] Docker Daemon Log Limit Check"
if command_exists docker; then
  docker_logging_driver="$(docker info 2>/dev/null | awk -F': ' '/Logging Driver/ {print $2; exit}' || true)"
  if [[ -n "${docker_logging_driver:-}" ]]; then
    log "Logging Driver: $docker_logging_driver"
  else
    log "Logging Driver: unknown"
  fi
else
  log "docker command is not available"
fi

docker_daemon_conf="$(find_docker_daemon_conf 2>/dev/null || true)"
if [[ -n "${docker_daemon_conf:-}" ]]; then
  max_size="$(extract_docker_log_opt "$docker_daemon_conf" "max-size")"
  max_file="$(extract_docker_log_opt "$docker_daemon_conf" "max-file")"
  compress="$(extract_docker_log_opt "$docker_daemon_conf" "compress")"
  log "Docker daemon config: $docker_daemon_conf"
  log "log-opts.max-size: ${max_size:-not set}"
  log "log-opts.max-file: ${max_file:-not set}"
  log "log-opts.compress: ${compress:-not set}"
  if [[ -n "${max_size:-}" && -n "${max_file:-}" ]]; then
    log "Log rotation: configured"
  else
    log "Log rotation: not configured"
  fi
else
  if [[ -f /etc/docker/daemon.json ]]; then
    log "Docker daemon config: /etc/docker/daemon.json (not readable)"
  else
    log "Docker daemon config: /etc/docker/daemon.json (not found)"
  fi
fi
log ""

section "[5] PostgreSQL Usage"
if [[ -f "$CONFIG_FILE" ]]; then
  pg_summary="$(extract_pg_summary "$CONFIG_FILE")"
  if [[ -n "${pg_summary:-}" ]]; then
    pg_host=$(printf '%s\n' "$pg_summary" | awk -F= '/^host=/{print $2}')
    pg_port=$(printf '%s\n' "$pg_summary" | awk -F= '/^port=/{print $2}')
    pg_database=$(printf '%s\n' "$pg_summary" | awk -F= '/^database=/{print $2}')
    log "Config File: $CONFIG_FILE"
    log "Host: ${pg_host:-unknown}"
    log "Port: ${pg_port:-unknown}"
    log "Database: ${pg_database:-unknown}"
    log "Service Type: $(classify_host "${pg_host:-}")"
  else
    log "PostgreSQL config not found in $CONFIG_FILE"
  fi
else
  log "Config file not found: $CONFIG_FILE"
fi
log ""

section "[6] Redis Usage"
if [[ -f "$CONFIG_FILE" ]]; then
  redis_found=0
  while IFS='|' read -r redis_name redis_host redis_port redis_db; do
    [[ -z "${redis_name:-}" ]] && continue
    redis_found=1
    log "Redis Instance: $redis_name"
    log "Host: ${redis_host:-unknown}"
    log "Port: ${redis_port:-unknown}"
    log "DB: ${redis_db:-unknown}"
    log "Service Type: $(classify_host "${redis_host:-}")"
    log "---"
  done < <(extract_redis_summary "$CONFIG_FILE")

  if [[ "$redis_found" -eq 0 ]]; then
    log "Redis config not found in $CONFIG_FILE"
  fi
else
  log "Config file not found: $CONFIG_FILE"
fi
log ""

section "[7] Summary"
if [[ -f "$CONFIG_FILE" ]]; then
  log "Config source: $CONFIG_FILE"
else
  log "Config source: missing"
fi
log "Customer deployment region: ${CAM_REGION:-unknown}"
if [[ -n "${pg_host:-}" ]]; then
  log "PostgreSQL service type: $(classify_host "${pg_host:-}")"
else
  log "PostgreSQL service type: unknown"
fi
if [[ "${redis_found:-0}" -eq 1 ]]; then
  redis_types="$(extract_redis_summary "$CONFIG_FILE" | awk -F'|' '{print $2}' | while read -r host; do
    case "$host" in
      "" ) echo "unknown" ;;
      127.0.0.1|localhost) echo "local" ;;
      *.rds.aliyuncs.com|*.redis.rds.aliyuncs.com|*.rds.amazonaws.com|*.cache.amazonaws.com|*.amazonaws.com|*.postgres.database.azure.com|*.redis.cache.windows.net|*.googleapis.com|*.cloudsql|*.aliyuncs.com) echo "cloud" ;;
      *) echo "remote" ;;
    esac
  done | sort -u | paste -sd ',' -)"
  log "Redis service type(s): ${redis_types:-unknown}"
else
  log "Redis service type(s): unknown"
fi
log ""
log "Environment check completed."
log "Please send this file to 1Token: $RESULT_FILE"
