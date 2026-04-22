#!/bin/bash
# CAM Environment Diagnostic Script
# This script checks system info, network, disk, docker, and SSH key status

set -euo pipefail

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
curl -s ipinfo.io
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
lsblk | grep data || echo "WARNING: No data disk found"
echo "------------------------------------------------"

# 6. Check Docker camauth container
echo "[6] Docker camauth Container Status"
docker ps -f name=camauth 2>/dev/null || echo "WARNING: Docker not running or no camauth container"
echo "------------------------------------------------"

# 7. Validate CAM-AUTH SSH Key
echo "[7] CAM-AUTH SSH Key Validation"
SSH_KEY_FILE=~/.camauth/id_rsa
SSH_PASS_FILE=~/.camauth/id_rsa_pass

# Check if the SSH key file exists
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "ERROR: SSH key file not found: $SSH_KEY_FILE"
else
    # Auto-load password if password file exists, otherwise prompt user input
    if [ -f "$SSH_PASS_FILE" ]; then
        echo "INFO: Password file detected, loading password automatically"
        SSH_PASS=$(cat "$SSH_PASS_FILE" 2>/dev/null)
    else
        echo "INFO: Password file not found, please enter password manually"
        read -s -p "Enter CAM-AUTH SSH key passphrase: " SSH_PASS
        echo ""
    fi

    # Verify SSH key passphrase
    ssh-keygen -y -f "$SSH_KEY_FILE" -P "$SSH_PASS" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "SUCCESS: CAM-AUTH SSH key validated"
    else
        echo "ERROR: Invalid passphrase for CAM-AUTH SSH key"
    fi
fi

echo "------------------------------------------------"
echo ""
echo "=============================================="
echo "          Environment Check Completed         "
echo "=============================================="
