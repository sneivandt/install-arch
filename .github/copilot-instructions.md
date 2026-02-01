# Copilot Instructions for install-arch

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
