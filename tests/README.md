# tests/

Lint + unit tests for `check_auth.sh`, all runnable in a single Docker
container.

## Run

```bash
bash tests/run-in-docker.sh
```

This builds an Ubuntu 24.04 image with `shellcheck`, `bats`, `jq`,
`openssh-client`, etc., then runs `tests/run.sh` inside it.

`tests/run.sh` does two things:

1. `tests/lint.sh` — runs `shellcheck` against `check_auth.sh` and the
   shell scripts in `tests/`.
2. `bats tests/check_auth.bats` — runs the unit tests.

## How the unit tests work

`tests/check_auth.bats` invokes `check_auth.sh` in a sandbox per test:

- **Mocked PATH.** `tests/helpers.bash` puts a per-test `bin/` at the
  front of `$PATH` and writes tiny shell scripts to shadow `docker`,
  `lsblk`, `curl`, `lsb_release`, `nproc`, `free`, and `clear`. Each
  test re-mocks whatever it needs.
- **Sandboxed `$HOME`.** `~/.camauth/` is redirected to the test's
  temp dir, so SSH keys are generated fresh per test using
  `ssh-keygen`.
- **Real `/etc/docker/daemon.json`.** The script hardcodes this path;
  inside the container we run as root and the tests write/remove the
  file directly.

## Expected red, not noise

Both `shellcheck` and `bats` are expected to surface real issues in
`check_auth.sh` today. That is the point of adding the suite — the
script's owners can decide whether/when to fix.

`shellcheck` reports (advisory):

- `SC2181` x2 — `cmd; if [ $? -eq 0 ]` should be `if cmd; then ...`
- `SC2162` — `read` without `-r`

`bats` failures driven by the same root cause:

- `log rotation: missing keys -> WARNING`
- `ssh key: invalid passphrase -> ERROR`

Both follow the pattern

```bash
some_command
if [ $? -eq 0 ]; then ... else ... fi
```

Under `set -e`, `some_command` failing aborts the script before the
`if` can run, so the `else` branch is dead code. Replacing with
`if some_command; then ... else ... fi` flips both red signals to green.
