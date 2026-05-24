# Copilot Instructions for install-arch

## Repository context

This repository contains `install-arch.sh`, a destructive Arch Linux installer
that provisions encrypted LVM, users, bootloader configuration, system services,
and dotfiles. Treat changes as safety-critical: a bad edit can destroy data or
leave a machine unbootable.

## Always-on principles

- Prefer small, behavior-preserving changes unless the user explicitly asks for
  a behavior change.
- Preserve `--dry-run` and `--test-mode` behavior for every installer change.
- Keep shell code ShellCheck-clean, quote variables, avoid `eval`, and fail
  loudly instead of silently continuing after invalid input.
- Never test destructive operations on a real disk. Use dry-run, containers,
  VMs, or loop devices.
- Update `README.md`, tests, and CI expectations when user-visible behavior,
  paths, package lists, or validation commands change.
- Do not commit secrets, passwords, machine-specific credentials, or private
  configuration.

## Repo-specific skills

Detailed guidance is split into focused skills under `.github/skills/`:

- `arch-installer-safety`: use when changing disk, encryption, LVM, boot,
  chroot, sudo, user, service, or other safety-sensitive installer behavior.
- `arch-installer-testing`: use when validating installer changes, updating
  tests, or working with dry-run/test-mode/integration-test flows.
- `arch-installer-maintenance`: use when adding features, changing packages,
  working with dialog prompts, dotfiles integration, docs, or repo workflow.

## Project structure

```text
.
├── install-arch.sh
├── test/
│   ├── unit_tests.sh
│   ├── integration_test.sh
│   └── test_helpers.sh
├── .github/
│   ├── workflows/ci.yml
│   ├── skills/
│   └── copilot-instructions.md
└── README.md
```

## Current validation commands

Run the smallest relevant subset, usually:

```bash
bash -n install-arch.sh test/*.sh
shellcheck install-arch.sh test/*.sh
./test/unit_tests.sh
```

Use `sudo ./test/integration_test.sh` only when root/loop-device access is
available and appropriate.
