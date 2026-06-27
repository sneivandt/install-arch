---
name: arch-installer-safety
description: Use when modifying install-arch.sh safety-sensitive behavior, including disk partitioning, encryption, LVM, chroot operations, bootloader/initramfs config, sudo, users, services, or cleanup.
---

# Arch Installer Safety

Use this skill for changes that could affect data loss, bootability, system
security, or install reliability.

## Safety invariants

- Keep `set -o errexit`, `set -o nounset`, and `set -o pipefail`.
- Preserve the central helpers in `install-arch.sh` (`run_cmd`, `in_target`,
  `as_user`, `write_file`, `append_file`, `enable_services`) instead of
  duplicating dry-run or chroot logic.
- Quote variables, arrays, paths, command substitutions, and heredoc inputs
  correctly.
- Validate all user-controlled values before use: mode, hostname, username,
  target device, LUKS password, selected driver, and paths.
- Fail closed with clear errors. Do not add broad catches, silent fallbacks, or
  early returns that hide invalid state.

## Destructive operations

- Confirm the target is root-run, UEFI-booted, online, a block device, large
  enough, unmounted, and not already using installer names such as `cryptlvm` or
  `volgroup0`.
- Never remove broad paths or use broad destructive commands without explicit
  target validation.
- Wait for partition nodes after changing partition tables.
- Keep cleanup idempotent: unmount `/mnt`, swapoff the installer swap LV,
  deactivate `volgroup0`, and close `cryptlvm` when present.

## Storage, encryption, and boot

- Use LUKS2 for encrypted root: `cryptsetup luksFormat --type luks2`.
- Do not log passwords. Prefer stdin/key-file patterns and unset password
  variables after use.
- Preserve device suffix handling for NVMe, eMMC, and loop devices.
- Preserve GRUB encrypted-root configuration through `/etc/default/grub` using
  the LUKS partition UUID so both `linux` and `linux-lts` entries are covered.
- Preserve mkinitcpio hooks needed for encrypted LVM boot.

## Chroot, sudo, and services

- Use `in_target` for `arch-chroot /mnt ...` commands.
- Use `as_user` for target-user commands so `HOME`, `USER`, and `LOGNAME` are
  correct.
- Prefer sudoers drop-ins validated with `visudo -cf /etc/sudoers`; avoid
  editing `/etc/sudoers` directly.
- Enable services through `enable_services` unless a command needs special
  sequencing.
