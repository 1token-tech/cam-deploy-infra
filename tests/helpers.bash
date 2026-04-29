# Helpers for check_auth.bats. Loaded via `load helpers` in bats files.
# shellcheck shell=bash

# Create a per-test bin/ directory at the front of PATH so we can shadow
# real binaries (docker, lsblk, curl, etc.) with mocks.
setup_mock_bin() {
    MOCK_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"
    export MOCK_BIN
    export PATH="$MOCK_BIN:$PATH"
}

# mock_cmd <name> <body>
# Writes a small bash script at $MOCK_BIN/<name> with the given body.
mock_cmd() {
    local name="$1"
    local body="$2"
    cat > "$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
$body
EOF
    chmod +x "$MOCK_BIN/$name"
}

# Redirect $HOME so check_auth.sh reads keys from a sandbox.
setup_fake_home() {
    HOME="$BATS_TEST_TMPDIR/home"
    export HOME
    mkdir -p "$HOME/.camauth"
}

# Generate a tiny RSA key with a known passphrase.
generate_ssh_key() {
    local key="$1"
    local pass="$2"
    ssh-keygen -t rsa -b 2048 -f "$key" -N "$pass" -q
}

run_check_auth() {
    bash "$BATS_TEST_DIRNAME/../check_auth.sh" "$@"
}
