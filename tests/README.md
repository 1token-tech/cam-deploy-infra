# tests/

Lint + unit tests for `check_auth.sh`, all runnable in a single Docker
container.

## Run

```bash
bash tests/run-in-docker.sh
```

This builds an Ubuntu 24.04 image with `shellcheck`, `bats`, `python3`,
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

## Coverage focus

The suite exercises the regressions that matter most for
`check_auth.sh`:

- `set -e` safe conditionals for Docker log checks and SSH key
  validation
- exact `/data` mount detection instead of broad substring matching
- exact `camauth` container presence checks instead of trusting
  `docker ps` exit status alone
- structured python JSON validation for `daemon.json`
- SSH passphrase validation without exposing the passphrase in process
  arguments
