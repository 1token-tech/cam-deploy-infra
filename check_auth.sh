#!/bin/bash
# CAM Environment Diagnostic Script
# This script checks system info, network, disk, docker, and SSH key status

set -euo pipefail

RED='\033[31m'
RESET='\033[0m'

print_error() {
    printf '%b%s%b\n' "$RED" "$1" "$RESET"
}

create_ssh_askpass() {
    local askpass_script
    askpass_script=$(mktemp "${TMPDIR:-/tmp}/camauth-askpass.XXXXXX")
    cat > "$askpass_script" <<'EOF'
#!/bin/sh
cat <&3
EOF
    chmod 700 "$askpass_script"
    printf '%s\n' "$askpass_script"
}

docker_log_limit_configured() {
    local docker_conf="$1"

    if command -v jq >/dev/null 2>&1; then
        jq_rc=0
        jq -e '.["log-opts"]?["max-size"] and .["log-opts"]?["max-file"]' "$docker_conf" >/dev/null 2>&1 || jq_rc=$?
        if [ "$jq_rc" -eq 0 ]; then
            return 0
        fi
        if [ "$jq_rc" -ne 127 ]; then
            return 1
        fi
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$docker_conf" >/dev/null 2>&1 <<'EOF'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

log_opts = data.get("log-opts") or {}
sys.exit(0 if log_opts.get("max-size") and log_opts.get("max-file") else 1)
EOF
        return
    fi

    return 1
}

clear
echo "=============================================="
echo "           CAM Environment Check              "
echo "=============================================="
echo ""

# 1. Check CAM_REGION environment variable
echo "[1] CAM_REGION Environment Variable"
env | grep CAM_REGION || echo "CAM_REGION environment variable is not set"
echo "------------------------------------------------"

# 2. Check public IP information
echo "[2] Public IP Information"
curl -fsS --connect-timeout 3 --max-time 5 ipinfo.io 2>/dev/null || echo "public ip lookup unavailable (blocked/timeout)"
echo ""
echo "------------------------------------------------"

# 3. Check OS version
echo "[3] Operating System Version"
lsb_release -a 2>/dev/null || echo "lsb_release command is not supported on this system"
echo "------------------------------------------------"

# 4. Check CPU and Memory info
echo "[4] CPU / Memory Information"
echo "CPU Cores: $(nproc)"
echo "Total Memory: $(free -h | awk '/^Mem:/ {print $2}')"
echo "------------------------------------------------"

# 5. Check data disk
echo "[5] Data Disk Check"
if DATA_DISK_ROWS=$(lsblk -o NAME,MOUNTPOINT 2>/dev/null | awk '$(NF) == "/data" { print; found=1 } END { exit found ? 0 : 1 }'); then
    echo "$DATA_DISK_ROWS"
else
    echo "WARNING: No data disk found"
fi
echo "------------------------------------------------"

# 6. Check Docker camauth container
echo "[6] Docker camauth Container Status"
if CAMAUTH_CONTAINER=$(docker ps --filter 'name=^/camauth$' --format '{{.Names}}\t{{.Status}}' 2>/dev/null); then
    if [ -n "$CAMAUTH_CONTAINER" ]; then
        echo "$CAMAUTH_CONTAINER"
    else
        echo "WARNING: camauth container not found"
    fi
else
    echo "WARNING: Docker not running or unavailable"
fi
echo "------------------------------------------------"

# 7. Check Docker daemon log rotation configuration
echo "[7] Docker Daemon Log Limit Check"
DOCKER_CONF="/etc/docker/daemon.json"

if [ ! -f "$DOCKER_CONF" ]; then
    print_error "ERROR: Docker daemon config file $DOCKER_CONF not found"
else
    echo "INFO: Found Docker config: $DOCKER_CONF"
    if command -v jq >/dev/null 2>&1; then
        jq . "$DOCKER_CONF" 2>/dev/null || cat "$DOCKER_CONF"
    else
        cat "$DOCKER_CONF"
    fi

    # Check log size limit using structured JSON keys rather than string matching.
    if docker_log_limit_configured "$DOCKER_CONF"; then
        echo -e "\nSUCCESS: Container log rotation is configured (max-size + max-file)"
    else
        echo -e "\nWARNING: No global log size limit configured in Docker daemon"
    fi
fi
echo "------------------------------------------------"

# 8. Validate CAM-AUTH SSH Key
echo "[8] CAM-AUTH SSH Key Validation"
SSH_KEY_FILE=~/.camauth/id_rsa
SSH_PASS_FILE=~/.camauth/id_rsa_pass

# Check if the SSH key file exists
if [ ! -f "$SSH_KEY_FILE" ]; then
    print_error "ERROR: SSH key file not found: $SSH_KEY_FILE"
else
    # Auto-load password if password file exists, otherwise prompt user input
    if [ -f "$SSH_PASS_FILE" ]; then
        echo "INFO: Password file detected, loading password automatically"
        SSH_PASS=$(cat "$SSH_PASS_FILE" 2>/dev/null)
    else
        echo "INFO: Password file not found, please enter password manually"
        read -r -s -p "Enter CAM-AUTH SSH key passphrase: " SSH_PASS
        echo ""
    fi

    # Verify the key without exposing the passphrase in process arguments.
    SSH_ASKPASS_SCRIPT=$(create_ssh_askpass)
    if SSH_ASKPASS="$SSH_ASKPASS_SCRIPT" SSH_ASKPASS_REQUIRE=force DISPLAY=dummy \
        ssh-keygen -y -f "$SSH_KEY_FILE" >/dev/null 2>&1 </dev/null 3<<<"$SSH_PASS"; then
        echo "SUCCESS: CAM-AUTH SSH key validated"
    else
        print_error "ERROR: Invalid passphrase for CAM-AUTH SSH key"
    fi
    rm -f "$SSH_ASKPASS_SCRIPT"
    unset SSH_PASS
fi

echo "------------------------------------------------"
echo ""
echo "=============================================="
echo "          Environment Check Completed         "
echo "=============================================="
