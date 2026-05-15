#!/usr/bin/env bats
#
# Unit tests for check_auth.sh. Designed to run inside the test container
# (see tests/Dockerfile). Each test starts from a clean mocked $PATH and
# fake $HOME so check_auth.sh's external dependencies are deterministic.
#
load helpers

setup() {
    setup_mock_bin
    setup_fake_home

    # Defaults that keep the script from hitting the real system.
    mock_cmd clear 'true'
    mock_cmd nproc 'echo 4'
    mock_cmd free 'printf "              total\nMem:           8.0Gi\n"'
    mock_cmd lsblk 'echo "sda           8:0   100G  /data"'
    mock_cmd docker 'echo "CONTAINER ID   NAME"'
    mock_cmd curl 'echo "8.8.8.8 mock-isp"'
    mock_cmd lsb_release 'echo "Ubuntu 24.04 LTS"'

    # Each test owns /etc/docker/daemon.json explicitly.
    rm -f /etc/docker/daemon.json
    mkdir -p /etc/docker
}

# ---------- CAM_REGION ----------

@test "CAM_REGION: prints value when set" {
    export CAM_REGION=us-east-1
    run run_check_auth
    [[ "$output" == *"CAM_REGION=us-east-1"* ]]
}

@test "CAM_REGION: prints not-set message when unset" {
    unset CAM_REGION || true
    run run_check_auth
    [[ "$output" == *"CAM_REGION environment variable is not set"* ]]
}

# ---------- public IP ----------

@test "public IP: shows curl output on success" {
    mock_cmd curl 'echo "1.2.3.4 mock-output"'
    run run_check_auth
    [[ "$output" == *"1.2.3.4 mock-output"* ]]
}

@test "public IP: shows fallback when curl times out" {
    mock_cmd curl 'exit 28'  # 28 = CURLE_OPERATION_TIMEDOUT
    run run_check_auth
    [[ "$output" == *"public ip lookup unavailable"* ]]
}

# ---------- OS ----------

@test "OS: shows lsb_release output" {
    mock_cmd lsb_release 'echo "Ubuntu 22.04 mock"'
    run run_check_auth
    [[ "$output" == *"Ubuntu 22.04 mock"* ]]
}

@test "OS: falls back when lsb_release missing" {
    mock_cmd lsb_release 'exit 127'
    run run_check_auth
    [[ "$output" == *"lsb_release command is not supported"* ]]
}

# ---------- CPU / Memory ----------

@test "CPU/Mem: prints nproc and parsed free output" {
    mock_cmd nproc 'echo 16'
    mock_cmd free 'printf "              total        used\nMem:           32Gi         1Gi\n"'
    run run_check_auth
    [[ "$output" == *"CPU Cores: 16"* ]]
    [[ "$output" == *"Total Memory: 32Gi"* ]]
}

# ---------- data disk ----------

@test "data disk: shows row when /data is present" {
    mock_cmd lsblk 'echo "sdb 8:16 200G /data"'
    run run_check_auth
    [[ "$output" == *"/data"* ]]
}

@test "data disk: warns when no /data row" {
    mock_cmd lsblk 'echo "sda 8:0 100G /"'
    run run_check_auth
    [[ "$output" == *"WARNING: No data disk found"* ]]
}

@test "data disk: does not treat substring matches as /data" {
    mock_cmd lsblk 'echo "sda 8:0 100G /metadata"'
    run run_check_auth
    [[ "$output" == *"WARNING: No data disk found"* ]]
}

# ---------- docker camauth container ----------

@test "docker: warns when docker is up but camauth container is absent" {
    mock_cmd docker 'exit 0'
    run run_check_auth
    [[ "$output" == *"WARNING: camauth container not found"* ]]
}

@test "docker: prints camauth container details when present" {
    mock_cmd docker 'echo "camauth\tUp 3 hours"'
    run run_check_auth
    [[ "$output" == *"camauth"* ]]
    [[ "$output" != *"WARNING: camauth container not found"* ]]
}

# ---------- docker daemon log rotation ----------

@test "log rotation: missing daemon.json -> ERROR" {
    rm -f /etc/docker/daemon.json
    run run_check_auth
    [[ "$output" == *"ERROR: Docker daemon config file"* ]]
}

@test "log rotation: max-size + max-file present -> SUCCESS" {
    cat > /etc/docker/daemon.json <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    run run_check_auth
    [[ "$output" == *"SUCCESS: Container log rotation is configured"* ]]
}

@test "log rotation: missing keys -> WARNING" {
    cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file" }
EOF
    run run_check_auth
    [[ "$output" == *"WARNING: No global log size limit"* ]]
}

@test "log rotation: unrelated strings do not count as log rotation settings" {
    cat > /etc/docker/daemon.json <<'EOF'
{ "note": "max-size max-file" }
EOF
    run run_check_auth
    [[ "$output" == *"WARNING: No global log size limit"* ]]
}

@test "log rotation: falls back to python3 when jq is unavailable" {
    cat > /etc/docker/daemon.json <<'EOF'
{ "log-opts": { "max-size": "500m", "max-file": "5", "compress": "true" } }
EOF

    mock_cmd jq 'exit 127'
    mock_cmd python3 "$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

input_file="${@: -1}"
grep -q '"max-size"' "$input_file"
grep -q '"max-file"' "$input_file"
EOF
)"

    run run_check_auth
    [[ "$output" == *"SUCCESS: Container log rotation is configured"* ]]
}

# ---------- SSH key ----------

@test "ssh key: missing key file -> ERROR" {
    rm -rf "$HOME/.camauth"
    run run_check_auth
    [[ "$output" == *"ERROR: SSH key file not found"* ]]
}

@test "ssh key: valid passphrase from password file -> SUCCESS" {
    local key="$HOME/.camauth/id_rsa"
    generate_ssh_key "$key" "secret123"
    printf '%s' "secret123" > "$HOME/.camauth/id_rsa_pass"
    run run_check_auth
    [[ "$output" == *"SUCCESS: CAM-AUTH SSH key validated"* ]]
}

@test "ssh key: invalid passphrase -> ERROR" {
    local key="$HOME/.camauth/id_rsa"
    generate_ssh_key "$key" "secret123"
    printf '%s' "wrongpass" > "$HOME/.camauth/id_rsa_pass"
    run run_check_auth
    [[ "$output" == *"ERROR: Invalid passphrase"* ]]
}

@test "ssh key: invalid passphrase error is printed in red" {
    local key="$HOME/.camauth/id_rsa"
    local red=$'\033[31m'
    local reset=$'\033[0m'

    generate_ssh_key "$key" "secret123"
    printf '%s' "wrongpass" > "$HOME/.camauth/id_rsa_pass"

    run run_check_auth
    [[ "$output" == *"${red}ERROR: Invalid passphrase for CAM-AUTH SSH key${reset}"* ]]
}

@test "ssh key: does not pass passphrase on command line" {
    local key="$HOME/.camauth/id_rsa"
    printf '%s\n' "dummy private key" > "$key"
    printf '%s' "secret123" > "$HOME/.camauth/id_rsa_pass"

    mock_cmd ssh-keygen "$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case " $* " in
  *" -P "*|*" secret123 "*)
    exit 99
    ;;
esac

if [ -z "${SSH_ASKPASS:-}" ]; then
    exit 98
fi

passphrase="$("$SSH_ASKPASS")"
[ "$passphrase" = "secret123" ] || exit 97
exit 0
EOF
)"

    run run_check_auth
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SUCCESS: CAM-AUTH SSH key validated"* ]]
}
