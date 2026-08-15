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
- `--test-mode` should avoid interactive `dialog` prompts, expose enough output
  for assertions, and require `--dry-run` by default.
- Destructive test mode requires `--allow-destructive-test-mode`, every required
  `TEST_MODE_*` variable, and a disposable loop device. Never use the opt-in
  with a physical disk.
- Keep dry-run output stable when tests assert on command structure.
- Source production helpers and package arrays from `install-arch.sh`; do not
  copy their implementations into test helpers.

## Safety boundaries

- Never validate destructive paths on a real disk.
- Test cleanup may release only resources created by that test run. Never use
  broad operations such as `swapoff -a` or unmount a shared `/mnt`.
- Use VMs, containers, disposable loop devices, or dry-run/test-mode for install
  flows.
- If a command requires root and the current session is not root, state that it
  was not run rather than faking coverage.
