#!/usr/bin/env bash
# Unit tests for install-arch.sh
set -o nounset
set -o pipefail

# Load test helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"

echo "========================================"
echo "Running install-arch.sh Unit Tests"
echo "========================================"
echo ""

# Test 1: Device prefix logic for NVMe devices
test_device_prefix_nvme() {
  local device="/dev/nvme0n1"
  local result
  result=$(get_device_prefix "$device")
  assert_equals "p" "$result" "NVMe device should have 'p' prefix"
}

# Test 2: Device prefix logic for SATA/SSD devices
test_device_prefix_sata() {
  local device="/dev/sda"
  local result
  result=$(get_device_prefix "$device")
  assert_equals "" "$result" "SATA device should have no prefix"
}

# Test 3: Partition naming for NVMe
test_partition_naming_nvme() {
  local device="/dev/nvme0n1"
  local result
  result=$(get_partition_name "$device" "1")
  assert_equals "/dev/nvme0n1p1" "$result" "NVMe partition 1 naming"
  
  result=$(get_partition_name "$device" "2")
  assert_equals "/dev/nvme0n1p2" "$result" "NVMe partition 2 naming"
}

# Test 4: Partition naming for SATA
test_partition_naming_sata() {
  local device="/dev/sda"
  local result
  result=$(get_partition_name "$device" "1")
  assert_equals "/dev/sda1" "$result" "SATA partition 1 naming"
  
  result=$(get_partition_name "$device" "2")
  assert_equals "/dev/sda2" "$result" "SATA partition 2 naming"
}

# Test 5: Hostname validation - valid hostnames
test_hostname_validation_valid() {
  local hostnames=("myhost" "test-host" "host123" "h" "a1b2c3")
  local passed=0
  local total=${#hostnames[@]}
  
  for hostname in "${hostnames[@]}"; do
    if validate_hostname "$hostname"; then
      ((passed++))
    fi
  done
  
  assert_equals "$total" "$passed" "All valid hostnames should pass validation"
}

# Test 6: Hostname validation - invalid hostnames
test_hostname_validation_invalid() {
  local hostnames=("-startwithhyphen" "endwithhyphen-" "has space" "has_underscore" "")
  local failed=0
  local total=${#hostnames[@]}
  
  for hostname in "${hostnames[@]}"; do
    if ! validate_hostname "$hostname"; then
      ((failed++))
    fi
  done
  
  assert_equals "$total" "$failed" "All invalid hostnames should fail validation"
}

# Test 7: Username validation - valid usernames
test_username_validation_valid() {
  local usernames=("user" "test_user" "user123" "a" "test-user")
  local passed=0
  local total=${#usernames[@]}
  
  for username in "${usernames[@]}"; do
    if validate_username "$username"; then
      ((passed++))
    fi
  done
  
  assert_equals "$total" "$passed" "All valid usernames should pass validation"
}

# Test 8: Username validation - invalid usernames
test_username_validation_invalid() {
  local usernames=("User" "123user" "-user" "user space" "")
  local failed=0
  local total=${#usernames[@]}
  
  for username in "${usernames[@]}"; do
    if ! validate_username "$username"; then
      ((failed++))
    fi
  done
  
  assert_equals "$total" "$failed" "All invalid usernames should fail validation"
}

# Test 9: Package name validation
test_package_validation() {
  local valid_packages=("base" "linux" "grub" "linux-firmware" "base-devel" "xorg-server")
  local invalid_packages=("" "-invalid" "has space" "has/slash")
  
  local valid_passed=0
  for pkg in "${valid_packages[@]}"; do
    if validate_package_name "$pkg"; then
      ((valid_passed++))
    fi
  done
  assert_equals "${#valid_packages[@]}" "$valid_passed" "Valid package names should pass"
  
  local invalid_failed=0
  for pkg in "${invalid_packages[@]}"; do
    if ! validate_package_name "$pkg"; then
      ((invalid_failed++))
    fi
  done
  assert_equals "${#invalid_packages[@]}" "$invalid_failed" "Invalid package names should fail"
}

# Test 10: Script syntax check
test_script_syntax() {
  local script_path="$SCRIPT_DIR/../install-arch.sh"
  if [ -f "$script_path" ]; then
    assert_command_success "Script syntax is valid" bash -n "$script_path"
  else
    test_fail "Script syntax check" "Script file not found: $script_path"
  fi
}

# Test 11: Script is executable
test_script_executable() {
  local script_path="$SCRIPT_DIR/../install-arch.sh"
  if [ -f "$script_path" ] && [ -x "$script_path" ]; then
    test_pass "Script is executable"
  else
    test_fail "Script is executable" "Script is not executable: $script_path"
  fi
}

# Test 12: Validate all packages in base package list
# NOTE: This package list is duplicated from install-arch.sh for validation.
# If packages are added/removed in the main script, update this list accordingly.
# Future enhancement: Extract package list dynamically from install-arch.sh
test_base_packages() {
  local base_packages=(
    "base" "base-devel" "bat" "btop" "ctags" "curl" "dash" "dhcpcd" 
    "docker" "duf" "efibootmgr" "eza" "fd" "fzf" "git" "git-delta" 
    "grub" "jq" "lazygit" "linux" "linux-firmware" "linux-headers" 
    "lvm2" "man-db" "man-pages" "neovim" "openssh" "pacman-contrib" 
    "ripgrep" "sed" "shellcheck" "tmux" "vim" "wget" "xdg-user-dirs" 
    "zip" "zoxide" "zsh" "zsh-autosuggestions" "zsh-completions" 
    "zsh-syntax-highlighting"
  )
  
  local passed=0
  for pkg in "${base_packages[@]}"; do
    if validate_package_name "$pkg"; then
      ((passed++))
    fi
  done
  
  assert_equals "${#base_packages[@]}" "$passed" "All base packages have valid names"
}

# Test 13: Validate GUI packages
# NOTE: This package list is duplicated from install-arch.sh for validation.
# If packages are added/removed in the main script, update this list accordingly.
# Future enhancement: Extract package list dynamically from install-arch.sh
test_gui_packages() {
  local gui_packages=(
    "adobe-source-code-pro-fonts" "alacritty" "alsa-utils" "chromium" 
    "dunst" "feh" "flameshot" "noto-fonts-cjk" "noto-fonts-emoji" 
    "papirus-icon-theme" "picom" "redshift" "rofi" "rxvt-unicode" 
    "urxvt-perls" "xclip" "xmonad" "xmonad-contrib" "xorg" 
    "xorg-server" "xorg-xinit" "xterm"
  )
  
  local passed=0
  for pkg in "${gui_packages[@]}"; do
    if validate_package_name "$pkg"; then
      ((passed++))
    fi
  done
  
  assert_equals "${#gui_packages[@]}" "$passed" "All GUI packages have valid names"
}

# Test 14: Test mode environment variables
test_test_mode_vars() {
  # This test just checks that we can export test mode variables
  export TEST_MODE_MODE="1"
  export TEST_MODE_HOSTNAME="testhost"
  export TEST_MODE_USER="testuser"
  export TEST_MODE_PASSWORD="testpass"
  export TEST_MODE_DEVICE="/dev/loop0"
  export TEST_MODE_LUKS_PASSWORD="lukspass"
  
  assert_not_empty "$TEST_MODE_MODE" "TEST_MODE_MODE should be set"
  assert_not_empty "$TEST_MODE_HOSTNAME" "TEST_MODE_HOSTNAME should be set"
  assert_not_empty "$TEST_MODE_USER" "TEST_MODE_USER should be set"
  assert_not_empty "$TEST_MODE_PASSWORD" "TEST_MODE_PASSWORD should be set"
  assert_not_empty "$TEST_MODE_DEVICE" "TEST_MODE_DEVICE should be set"
  assert_not_empty "$TEST_MODE_LUKS_PASSWORD" "TEST_MODE_LUKS_PASSWORD should be set"
  
  # Clean up
  unset TEST_MODE_MODE TEST_MODE_HOSTNAME TEST_MODE_USER TEST_MODE_PASSWORD
  unset TEST_MODE_DEVICE TEST_MODE_LUKS_PASSWORD
}

# Test 15: Verify script has correct shebang
test_shebang() {
  local script_path="$SCRIPT_DIR/../install-arch.sh"
  if [ -f "$script_path" ]; then
    local first_line
    first_line=$(head -n 1 "$script_path")
    assert_equals "#!/usr/bin/env bash" "$first_line" "Script has correct shebang"
  else
    test_fail "Shebang check" "Script file not found"
  fi
}

# Run all tests
test_device_prefix_nvme
test_device_prefix_sata
test_partition_naming_nvme
test_partition_naming_sata
test_hostname_validation_valid
test_hostname_validation_invalid
test_username_validation_valid
test_username_validation_invalid
test_package_validation
test_script_syntax
test_script_executable
test_base_packages
test_gui_packages
test_test_mode_vars
test_shebang

# Print summary and exit with appropriate code
echo ""
print_test_summary
