# Agent instructions

`install-arch.sh` erases disks and configures encrypted LVM, boot, users,
services, and dotfiles. Treat changes as safety-critical.

## Always

- Prefer small, behavior-preserving changes unless a behavior change is requested.
- Preserve dry-run guards and non-destructive test-mode defaults. Never test
  destructive operations on a real disk.
- Quote shell variables, avoid `eval`, keep ShellCheck clean, and fail explicitly
  on invalid input or required-step failures.
- Cleanup may release only resources acquired by the current run.
- Source production helpers and package arrays in unit tests; do not copy them.
- Keep `README.md`, tests, and CI aligned with changes to behavior, packages,
  paths, or validation commands.
- Never commit secrets, passwords, or private configuration.

## Task guidance

Load the relevant skills; combine them when a change spans responsibilities.

| Task | Skill |
| --- | --- |
| Disk, encryption, LVM, boot, chroot, users, sudo, services, cleanup | [Safety](.agents/skills/arch-installer-safety/SKILL.md) |
| Packages, dotfiles compatibility, prompts, docs, repository workflow | [Maintenance](.agents/skills/arch-installer-maintenance/SKILL.md) |
| Validation, test design, dry-run/test-mode, CI coverage | [Testing](.agents/skills/arch-installer-testing/SKILL.md) |

Use `install-arch.sh` and `test/` as implementation sources, [README.md](README.md)
for usage, and [.github/workflows/ci.yml](.github/workflows/ci.yml) for CI.
