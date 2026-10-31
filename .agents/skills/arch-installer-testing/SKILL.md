---
name: arch-installer-testing
description: Validate install-arch changes or audit test and CI coverage. Use for production-helper unit tests, ShellCheck, syntax checks, dry-run/test-mode behavior, and isolated loop-device or VM tests.
---

# Arch Installer Testing

Choose coverage for the behavior changed. Read `test/unit_tests.sh`,
`test/test_helpers.sh`, and the relevant production helpers before adding tests.
Guidance-only edits need source, link, frontmatter, and routing review, not a
live installer run.

## Standard checks

Run the smallest relevant subset of the quality checks:

```bash
for script in install-arch.sh test/*.sh; do bash -n "$script" || exit; done
shellcheck install-arch.sh test/*.sh
./test/unit_tests.sh
```

Keep the syntax-check loop: `bash -n` parses only its first script argument,
so passing several script paths to one invocation silently misses the others.

For unattended installer dry-run coverage:

```bash
TEST_MODE_MODE=1 \
TEST_MODE_HOSTNAME=testhost \
TEST_MODE_USER=testuser \
TEST_MODE_PASSWORD=testpass \
TEST_MODE_DEVICE=/dev/loop0 \
TEST_MODE_LUKS_PASSWORD=lukspass \
  ./install-arch.sh --test-mode --dry-run
```

Use `sudo ./test/integration_test.sh` only with authorized root/loop-device
access. It allocates a 12 GiB image but runs the installer in dry-run mode:
it does not exercise real partitioning, `pacstrap`, chroot, or boot.

## Test-mode expectations

- Use `--test-mode --dry-run`, not interactive `--dry-run`, for routine checks.
  The interactive path currently prepares the live-ISO keyring and installs
  `dialog` even with `--dry-run`. Both paths write the diagnostic log at
  `/tmp/install-arch-debug.log`; neither is a zero-write sandbox.
- Installer dry-run must skip disk and target-system mutations. Keep dotfiles
  commands behind the installer wrappers; running dotfiles' own `--dry-run` is
  not equivalent and can bootstrap binaries or write state.
- `--test-mode` avoids dialogs and requires `--dry-run` unless destructive mode
  is explicitly enabled.
- Destructive test mode requires `--allow-destructive-test-mode`, every required
  `TEST_MODE_*` input, and a disposable loop device. The required inputs are
  mode, hostname, user, password, device, and LUKS password. Desktop dry runs
  may also set `TEST_MODE_VIDEO_DRIVER`.
- Source production helpers and arrays. Mock external boundaries, not the
  implementation being tested. The unit harness resets `errexit` after sourcing
  the installer so assertions can accumulate failures.

## Coverage that matters

- Cover modes 1, 2, and 3 when changing shared or desktop provisioning; include
  `--resume` to detect accidental formatting or package-install regressions.
- Assert command arguments, ordering, failure propagation, and absence of
  forbidden operations, not just successful exit or a `[DRY-RUN]` marker.
- Include cancel, invalid input, partial failure, and owned/unowned cleanup
  cases for safety-sensitive changes.
- Package-name regex tests cannot detect removed packages or conflicts. Compare
  with current Arch metadata and active dotfiles package configuration.
- Dotfiles command-string assertions cannot detect removed upstream commands.
  Run `bash test/dotfiles_contract_test.sh` for the current release's parser
  contract; it requires authenticated `gh` access and verifies downloaded
  checksums and provenance before invoking help with production arguments.
  It does not prove package/chroot compatibility. Use an isolated target for
  that coverage; never apply dotfiles to the development host as a test.

## Safety boundaries

- Never validate destructive paths on a real disk.
- Test cleanup may release only resources created by that test run. Never use
  broad operations such as `swapoff -a` or unmount a shared `/mnt`.
- A privileged container can expose host block devices. Use only an explicitly
  disposable image/loop device or VM; containerization alone is not isolation.
- Distinguish syntax/unit/dry-run evidence from a real install and boot check.
  State unavailable coverage rather than inferring success from mocks.
