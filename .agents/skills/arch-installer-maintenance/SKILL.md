---
name: arch-installer-maintenance
description: Review or change install-arch package lists, dotfiles compatibility, dialog prompts, documentation, or repository workflow. Pair with arch-installer-safety for privileged behavior and arch-installer-testing for validation.
---

# Arch Installer Maintenance

Read the relevant helpers and call sites in `install-arch.sh` before editing.
Use the safety skill for chroot, service, account, or storage changes, and the
testing skill for validation.

## Package and mode changes

- Keep source package definitions in `BASE_PACKAGES`, `GUI_PACKAGES`, and
  `VBOX_PACKAGES`; runtime arrays may extend copies of those definitions.
- Separate boot/network/bootstrap prerequisites from dotfiles-owned applications.
  Before removing a duplicate, check whether an installer step needs it before
  dotfiles runs.
- Verify package availability, providers, and conflicts against current Arch
  metadata and dotfiles configuration. The unit tests check name syntax, not
  repository availability or transaction compatibility.
- Minimal mode uses the `base` dotfiles profile. Workstation and VirtualBox use
  the `desktop` profile.

## Dotfiles integration

1. Compare the installer with current
   [dotfiles](https://github.com/sneivandt/dotfiles) usage, CLI definitions,
   `conf/packages.toml`, `conf/systemd-units.toml`, and chroot provisioning code.
   Record the revision reviewed. The wrapper can download a release binary
   independently of the checkout; verify the release contract as well.
2. Reuse `prepare_dotfiles_checkout` for `/home/$user/src/dotfiles`. Preserve
   dirty or unrelated checkouts; resume must not overwrite them.
3. Use `as_user_dotfiles`, which preserves the target user's `HOME`, `USER`,
   and `LOGNAME` and sets `DOTFILES_PROVISIONING=arch-chroot`. Keep user-unit
   enablement offline and session-dependent work deferred to first login.
4. Validate the selected configuration before applying it. Current dotfiles
   uses `check` and `update`, not the legacy `test` and `install`.
   Verify accepted options before changing calls; use explicit profile/root
   selection and non-interactive execution. Preserve `--no-repo-update` so the
   update applies the checked checkout, and `--fail-on-skip` so incomplete
   applicable work is not reported as success. Save the selected machine profile
   only after validation succeeds.
5. Reconcile conflicting package policies across both repositories, particularly
   `rust` versus `rustup` and `pulseaudio` versus `pipewire-pulse`. The installer
   uses rustup and PipeWire; migration must retain package dependency checks.
   A rustup proxy alone is not a working toolchain: initialize stable Rust and
   verify Cargo and rustc as the target user before AUR builds. Do not disable
   download verification to make bootstrap succeed.

Do not execute the dotfiles wrapper on the host merely to inspect its CLI:
even `--help` can download and write a binary. Read source/help from an already
available binary, or use an explicitly isolated environment.

## Dialog and input prompts

- Use `dialog_capture` for values and `dialog_display` for confirmations.
  Preserve their explicit controlling-terminal input and separate output
  descriptor; plain stdout capture can break piped installation.
- Handle cancellation before mutation; retain `--defaultno` on destructive
  confirmation.
- Validate prompt outputs immediately.
- Use the existing dimension constants and readable labels. Preserve diagnostic
  metadata without logging passwords or passphrases.

## Documentation and workflow

- Keep `README.md`, `.github/workflows/ci.yml`, and
  `.github/pull_request_template.md` aligned with actual behavior and coverage.
- For guidance-only edits, check skill frontmatter, links, routing, and source
  accuracy; an installer run is unnecessary.
- Commit only when requested; use conventional commit style unless asked otherwise.
