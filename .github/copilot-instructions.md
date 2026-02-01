# Copilot Instructions for install-arch

## Overview

This repository contains a critical system installation script for automated Arch Linux provisioning with full disk encryption. The script handles sensitive operations including disk partitioning, encryption, user creation, and system configuration.

**Key Principles:**
- **Safety First**: This script can destroy data if misused. Every change must prioritize safety and validation.
- **Minimal Changes**: Make the smallest possible changes to accomplish the goal.
- **Test Thoroughly**: All changes must be tested in isolated environments (VMs, containers, loop devices).
- **Follow Standards**: Adhere strictly to shell scripting best practices and ShellCheck recommendations.

## Shell Scripting Guidelines

This repository contains a critical system installation script. Follow these strict guidelines when modifying shell scripts:

### General Shell Script Rules

1. **Always use set options for safety:**
   ```bash
   set -o errexit   # Exit on any error
   set -o nounset   # Exit on undefined variable
   set -o pipefail  # Exit if any command in a pipeline fails
   ```

2. **Quote all variables** to prevent word splitting and glob expansion:
   ```bash
   # Good
   echo "$variable"
   [ -z "$variable" ]
   
   # Bad
   echo $variable
   [ -z $variable ]
   ```

3. **Use explicit test operators:**
   - Use `[ ]` or `[[ ]]` for conditionals
   - Always quote variables in tests: `[ "$var" = "value" ]`
   - Use `-z` for empty string checks: `[ -z "$var" ]`
   - Use `-n` for non-empty string checks: `[ -n "$var" ]`

4. **Array handling:**
   - Quote array expansions: `"${array[@]}"`
   - Use proper array syntax for bash

5. **Function definitions:**
   - Use clear function syntax
   - Add comments explaining purpose
   - Return meaningful exit codes

6. **Error handling:**
   - Always use trap for error reporting with line numbers
   - Example: `trap 'echo "Error on line $LINENO"' ERR`
   - Validate all user input before use
   - Check exit codes of critical commands

7. **ShellCheck compliance:**
   - Run shellcheck on all shell scripts
   - Address all warnings unless explicitly disabled with reasoning
   - Use `# shellcheck disable=SCxxxx` sparingly and with comments

8. **Heredoc usage:**
   - Use proper quoting: `<<'EOF'` (no expansion) or `<<EOF` (with expansion)
   - Ensure proper indentation
   - Close with matching delimiter

9. **Command substitution:**
   - Use `$(command)` instead of backticks
   - Quote appropriately: `variable="$(command)"`

10. **Path handling:**
    - Use absolute paths where possible
    - Quote all paths
    - Validate paths exist before use

### Script-Specific Guidelines

1. **Dialog usage:**
   - Always check exit codes: `variable=$(dialog ...) || exit 1`
   - Clear screen after dialog: `--clear`
   - Validate dialog output is not empty

2. **Disk operations:**
   - Always verify disk/partition exists before operations
   - Use proper device naming with `$dpfx` for NVMe vs SATA/SSD
   - Never assume partition layout

3. **Encryption:**
   - Handle passwords securely
   - Never log passwords
   - Clear password variables when no longer needed

4. **Chroot operations:**
   - Use `arch-chroot` for Arch-specific operations
   - Ensure target is mounted before chroot
   - Quote all paths passed to chroot

5. **Logging:**
   - Redirect stdout and stderr appropriately
   - Use descriptive log messages
   - Log timestamps for debugging

### Code Review Checklist

Before committing changes, verify:
- [ ] shellcheck passes with no errors
- [ ] All variables are quoted
- [ ] Error handling is in place
- [ ] User input is validated
- [ ] Script runs without syntax errors (`bash -n script.sh`)
- [ ] Sensitive operations have safeguards
- [ ] Comments explain complex logic
- [ ] Code follows existing style in the file

### Testing Requirements

1. **Syntax checking:**
   ```bash
   bash -n install-arch.sh
   shellcheck install-arch.sh
   ```

2. **Never test destructive operations on real systems** - use VMs or containers

3. **Validate:**
   - Dialog flows work correctly
   - Error traps catch issues
   - File operations use correct paths
   - Commands exist before use

### Forbidden Patterns

❌ **Never do:**
- `rm -rf /` or similar destructive commands without explicit checks
- Unquoted variables in critical paths
- Ignoring exit codes of critical commands
- Running with `set +e` (disabling error checking) without good reason
- Using `eval` without careful consideration
- Parsing `ls` output

### Documentation

- Update README.md for user-visible changes
- Comment complex sections of code
- Document any assumptions about the environment
- Keep usage examples current

### CI/CD

- All changes must pass CI checks
- ShellCheck analysis must be clean
- Script syntax must be valid
- Manual testing should be performed in a VM before merging

## Project Structure

```
.
├── install-arch.sh          # Main installation script (critical)
├── tests/
│   ├── unit_tests.sh       # Unit tests for individual functions
│   └── integration_test.sh # Integration test with loop devices
├── .github/
│   ├── workflows/ci.yml    # CI/CD pipeline
│   └── copilot-instructions.md  # This file
└── README.md               # User documentation
```

## Common Tasks

### Adding a New Feature
1. Review existing code patterns in `install-arch.sh`
2. Add feature with minimal changes
3. Update relevant package arrays (`packages`, `packages_gui`)
4. Add unit tests if adding new functions
5. Run all tests locally before committing
6. Update README.md if user-visible
7. Test in a VM with actual installation

### Fixing a Bug
1. Identify the root cause
2. Add a test that reproduces the bug
3. Fix with minimal code changes
4. Verify all tests pass
5. Manually test the fix in isolation
6. Document the fix if it affects user behavior

### Modifying Package Lists
1. Check package availability: `pacman -Ss package-name`
2. Verify package name spelling
3. Consider mode-specific packages (minimal vs workstation)
4. Update comments explaining why packages are included
5. Test installation in appropriate mode

### Working with Dialog
- Dialog outputs to stderr, capture properly: `variable=$(dialog ... 2>&1)`
- Always validate dialog didn't fail/cancel: `|| exit 1`
- Use `--clear` to clean screen after dialog
- Set appropriate dialog dimensions for content

### Partition and Device Handling
- NVMe devices: `/dev/nvme0n1p1`, `/dev/nvme0n1p2`
- SATA/SSD devices: `/dev/sda1`, `/dev/sda2`
- Use `$dpfx` variable to handle naming differences
- Always verify device exists before operations: `[ -b "$device" ]`

### Encryption Operations
- Use LUKS2 (not LUKS1): `cryptsetup luksFormat --type luks2`
- Never echo passwords in logs
- Use variables for password passing to avoid command history
- Clear password variables: `unset password`
- Test unlock operations immediately after setup

### LVM Operations
- Physical volume: `pvcreate`
- Volume group: `vgcreate volgroup0`
- Logical volumes: `lvcreate -L 1G -n swap`, `lvcreate -l 100%FREE -n root`
- Always check operations succeeded before continuing

## Testing Strategy

### Unit Tests (`tests/unit_tests.sh`)
- Test individual functions in isolation
- Mock external dependencies
- Validate input handling and edge cases
- Fast execution (no system operations)
- Run before committing: `./tests/unit_tests.sh`

### Integration Tests (`tests/integration_test.sh`)
- Use loop devices to simulate real disks
- Test full installation flow without real hardware
- Requires root: `sudo ./tests/integration_test.sh`
- Validates partitioning, encryption, LVM setup
- Safe - no modifications to real disks

### Manual Testing
- Always test in a VM (VirtualBox, QEMU, etc.)
- Test all three modes: Minimal (1), Workstation (2), VirtualBox (3)
- Verify NVIDIA detection (if applicable)
- Test actual boot after installation
- Validate user can login and system is functional

### CI Pipeline
- ShellCheck analysis (must pass)
- Unit tests (automated)
- Integration tests in Docker (automated)
- Syntax validation (automated)

## Troubleshooting Guide

### Common Issues

**ShellCheck Warnings:**
- SC2086: Quote variables to prevent word splitting
- SC2046: Quote command substitution to prevent word splitting  
- SC2181: Check exit code directly: `if command; then` instead of `if [ $? -eq 0 ]; then`
- SC2002: Useless cat: Use `< file` instead of `cat file |`

**Dialog Issues:**
- Returns non-zero on cancel - always handle: `|| exit 1`
- Output goes to stderr - redirect properly: `2>&1`
- Requires large enough terminal - check dimensions

**Disk Operations:**
- Device busy: Ensure not mounted before operations
- LUKS unlock fails: Check password, device path
- LVM not found: May need `vgscan`, `vgchange -ay`

**Chroot Issues:**
- Command not found: Install in base system first
- Permission denied: Verify mount points before chroot
- Path issues: Use absolute paths inside chroot

## Security Considerations

### Secure Practices
- Full disk encryption (LUKS2) for root and swap
- Root account locked (`usermod -L root`)
- User in wheel group for sudo access
- Immutable DNS configuration (can be changed if needed)
- No hardcoded passwords or secrets
- Validate all user input before use

### Security Checklist
- [ ] No passwords in logs or command history
- [ ] No secrets in git repository
- [ ] Input validation for all user-provided data
- [ ] Proper file permissions (especially for sensitive files)
- [ ] LUKS encryption configured correctly
- [ ] Bootloader secured with encryption parameters

## Code Style Guidelines

### Formatting
- Indentation: 2 spaces (no tabs)
- Line length: Aim for <100 characters, but not strict
- Function declarations: `function_name() {` on same line
- Comments: `#` with space after, explain "why" not "what"

### Naming Conventions
- Variables: lowercase with underscores: `disk_device`, `user_name`
- Constants: UPPERCASE: `LOG_FILE`, `SWAP_SIZE`
- Functions: lowercase with underscores: `setup_disk()`, `install_packages()`
- Be descriptive: `target_disk` not `disk`, `luks_password` not `pwd`

### Best Practices
- Keep functions focused and single-purpose
- Extract repeated code into functions
- Use arrays for package lists
- Group related operations together
- Add comments before complex sections
- Use meaningful variable names

## Git Workflow

### Commit Messages
Follow conventional commit format:
- `feat: Add support for custom swap size`
- `fix: Correct NVMe device partition naming`
- `docs: Update README with new features`
- `test: Add unit tests for input validation`
- `refactor: Extract disk setup into function`
- `chore: Update CI workflow`

### Branch Strategy
- `main/master`: Stable, tested code
- Feature branches: `feature/description`
- Bug fixes: `fix/description`
- Documentation: `docs/description`

### Pull Requests
- Fill out the PR template completely
- Link related issues
- Describe testing performed
- Include screenshots for UI/output changes
- Ensure CI passes before requesting review

## Resources

### Documentation
- [Arch Linux Installation Guide](https://wiki.archlinux.org/title/Installation_guide)
- [LUKS Encryption](https://wiki.archlinux.org/title/Dm-crypt/Device_encryption)
- [LVM](https://wiki.archlinux.org/title/LVM)
- [Bash Reference Manual](https://www.gnu.org/software/bash/manual/)
- [ShellCheck Wiki](https://www.shellcheck.net/wiki/)

### Tools
- ShellCheck: `shellcheck install-arch.sh`
- Bash syntax check: `bash -n install-arch.sh`
- Dialog for TUI: `man dialog`
- Testing in container: `docker run -it --privileged archlinux`

## Support and Contact

- Issues: Use GitHub Issues for bug reports and feature requests
- Discussions: Use GitHub Discussions for questions and ideas
- Contributing: See pull request template for contribution guidelines
