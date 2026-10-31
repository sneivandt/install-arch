---
name: arch-installer-safety
description: Review or change install-arch.sh disk, encryption, LVM, resume, boot/initramfs, chroot, sudo, user, service, or cleanup behavior. Use for changes that can destroy data, affect privileges, or leave the target unbootable.
---

# Arch Installer Safety

Trace the affected stage from input validation through mutation and cleanup.
Check fresh install, `--resume`, failure, and dry-run paths; use the testing
skill for non-destructive verification.

## Execution and diagnostics

- Preserve `errexit`, `errtrace`, `nounset`, `pipefail`, and the error, signal,
  and exit traps. Bash suppresses `errexit` inside functions used as conditions:
  check failures explicitly when adding conditional wrappers.
- Reuse `run_cmd`, `in_target`, `as_user`, `write_file`, `append_file`, and
  `enable_services` rather than bypassing dry-run or chroot handling.
- Use `run_required_step` for required configuration work. Reserve
  `run_optional_step` for genuinely nonessential work that may safely fail.
- Preserve normal command stdout/stderr, stage markers, and diagnostic context.
  Never log secret values; quoting alone does not make a secret safe to log.

## Destructive operations

- Preserve root, UEFI, network, tool, mount, device-type, and size checks before
  destructive work. Validate selections and retain explicit full-disk
  confirmation before wiping.
- Check that `cryptlvm` and `volgroup0` are unclaimed before acquisition.
- Wait for partition nodes after changing partition tables.
- Keep cleanup ownership flags accurate, including partial acquisition failures.
  A matching resource name is not evidence of ownership. Release owned swap,
  mounts, VG, and LUKS mapping in dependency order.
- Preserve unrelated resources and target files. Never use global swap,
  unmount, or LVM cleanup as a shortcut.

## Storage, encryption, and boot

- Use LUKS2 for encrypted root: `cryptsetup luksFormat --type luks2`.
- Pass encryption keys and password-hashing input through stdin, not command
  arguments. Validate hashes and unset plaintext variables after use.
- Preserve device suffix handling for NVMe, eMMC, and loop devices.
- Keep the LUKS UUID in `/etc/default/grub` and encryption/LVM initramfs hooks
  aligned with the installed kernel packages. The installer currently installs
  `linux`, not an LTS kernel.
- Treat `--resume` as reopening and validating an existing installation, not a
  fresh install. Never repartition, format, or run `pacstrap` on that path.
  Review partition, VG/LV, and target-system identity checks before reuse.
- Preserve atomic `fstab` replacement and resume-safe symlinks. Check failures
  before declaring the target bootable.

## Chroot, sudo, and services

- Use `in_target` for `arch-chroot /mnt ...` commands.
- Use `as_user` for target-user commands and `as_user_dotfiles` for dotfiles.
  Do not fake a live session bus or start user services inside the chroot.
- Reconcile only the intended regular user on resume. Preserve existing home
  contents and reject unsafe account or path identities.
- Validate sudoers drop-ins with `visudo -cf /etc/sudoers`. Remove temporary
  passwordless access on both success and failure; review recovery access when
  changing root locking or sudo setup order.
- Enable system services through `enable_services`; do not start host services
  while configuring the target.
