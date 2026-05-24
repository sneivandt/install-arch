---
name: arch-installer-maintenance
description: Use when adding installer features, changing package lists, working with dialog prompts, dotfiles integration, docs, project workflow, or other non-storage maintenance tasks.
---

# Arch Installer Maintenance

Use this skill for routine feature work and repository maintenance that is not
primarily disk/encryption/boot safety logic.

## Feature and bug workflow

- Read nearby patterns in `install-arch.sh` before editing.
- Keep changes minimal, but complete across script, tests, docs, and CI.
- Add or update tests when adding functions, changing package lists, device
  naming, prompts, dry-run output, or dotfiles flow.
- Update `README.md` for user-visible behavior, paths, package sets, install
  modes, security posture, or troubleshooting changes.

## Package and mode changes

- Keep base packages in `packages`, desktop packages in `packages_gui`, and VM
  additions in `packages_vbox`.
- Consider dotfiles-owned packages before adding installer-owned packages; avoid
  duplicating dotfiles AUR/package responsibilities.
- Verify Arch package names and keep tests in sync with package arrays.
- Minimal mode uses the `base` dotfiles profile. Workstation and VirtualBox use
  the `desktop` profile.

## Dotfiles integration

- Clone dotfiles to `/home/$user/src/dotfiles`.
- Run dotfiles as the target user through `as_user`.
- Validate with `dotfiles.sh test -p <profile>` before running
  `dotfiles.sh install -p <profile> -v`.
- Preserve `HOME`, `USER`, and `LOGNAME` when running dotfiles commands in the
  target system.

## Dialog and input prompts

- Capture dialog output with `--stdout --clear` and handle cancel/failure.
- Validate prompt outputs immediately.
- Keep prompt dimensions and labels readable in small terminals.

## Documentation and workflow

- Keep `.github/pull_request_template.md`, `.github/workflows/ci.yml`, and
  `README.md` aligned with actual script/test paths.
- Follow conventional commit style when committing unless the user asks
  otherwise.
