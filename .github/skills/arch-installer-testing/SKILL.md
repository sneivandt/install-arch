---
name: arch-installer-testing
description: Use when validating install-arch changes, updating tests, or working with dry-run, test-mode, ShellCheck, syntax checks, or loop-device integration tests.
---

# Arch Installer Testing

Use this skill whenever installer behavior, tests, package lists, dotfiles flow,
or CI expectations change.

## Standard checks

Run the smallest relevant subset first:

```bash
bash -n install-arch.sh test/*.sh
shellcheck install-arch.sh test/*.sh
./test/unit_tests.sh
```

For dry-run coverage:

```bash
TEST_MODE_MODE=1 \
TEST_MODE_HOSTNAME=testhost \
TEST_MODE_USER=testuser \
TEST_MODE_PASSWORD=testpass \
TEST_MODE_DEVICE=/dev/loop0 \
TEST_MODE_LUKS_PASSWORD=lukspass \
  ./install-arch.sh --test-mode --dry-run
```

Use `sudo ./test/integration_test.sh` only when root and loop-device access are
available.

## Test-mode expectations

- `--dry-run` must not mutate the host system.
- `--test-mode` should avoid interactive `dialog` prompts and expose enough
  output for assertions.
- Keep dry-run output stable when tests assert on command structure.
- Update `test/unit_tests.sh` when package arrays, device naming, or dotfiles
  command flow changes.

## Safety boundaries

- Never validate destructive paths on a real disk.
- Use VMs, containers, loop devices, or dry-run/test-mode for install flows.
- If a command requires root and the current session is not root, state that it
  was not run rather than faking coverage.
