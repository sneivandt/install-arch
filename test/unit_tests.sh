#!/usr/bin/env bash
# Unit tests for install-arch.sh
set -o nounset
set -o pipefail

# Load test helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=install-arch.sh
source "$SCRIPT_DIR/../install-arch.sh"
# Assertions accumulate failures for the final summary instead of exiting early.
set +o errexit

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

# Test 2b: Device prefix logic for eMMC devices
test_device_prefix_mmc() {
  local device="/dev/mmcblk0"
  local result
  result=$(get_device_prefix "$device")
  assert_equals "p" "$result" "eMMC device should have 'p' prefix"
}

# Test 2c: Device prefix logic for loop devices used by integration tests
test_device_prefix_loop() {
  local device="/dev/loop0"
  local result
  result=$(get_device_prefix "$device")
  assert_equals "p" "$result" "Loop device should have 'p' prefix"
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
  test_start "Script is executable"
  if [ -f "$script_path" ] && [ -x "$script_path" ]; then
    test_pass "Script is executable"
  else
    test_fail "Script is executable" "Script is not executable: $script_path"
  fi
}

# Test 12: Validate all packages in the installer's base package list
test_base_packages() {
  local passed=0
  for pkg in "${BASE_PACKAGES[@]}"; do
    if validate_package_name "$pkg"; then
      ((passed++))
    fi
  done

  assert_equals "${#BASE_PACKAGES[@]}" "$passed" "All base packages have valid names"
}

# Test 13: Validate the installer's GUI packages
test_gui_packages() {
  local passed=0
  for pkg in "${GUI_PACKAGES[@]}"; do
    if validate_package_name "$pkg"; then
      ((passed++))
    fi
  done

  assert_equals "${#GUI_PACKAGES[@]}" "$passed" "All GUI packages have valid names"
}

test_kernel_and_audio_packages() {
  local linux_count=0
  local linux_headers_count=0
  local lts_count=0
  local pipewire_count=0
  local pulseaudio_count=0
  local conflicting_audio_count=0
  local pkg

  for pkg in "${BASE_PACKAGES[@]}"; do
    case "$pkg" in
      linux)
        ((linux_count++))
        ;;
      linux-headers)
        ((linux_headers_count++))
        ;;
      linux-lts|linux-lts-headers)
        ((lts_count++))
        ;;
    esac
  done

  for pkg in "${GUI_PACKAGES[@]}"; do
    case "$pkg" in
      pipewire)
        ((pipewire_count++))
        ;;
      pulseaudio)
        ((pulseaudio_count++))
        ;;
      pipewire-pulse|wireplumber)
        ((conflicting_audio_count++))
        ;;
    esac
  done

  assert_equals "1" "$linux_count" "Base packages include the current Arch kernel"
  assert_equals "1" "$linux_headers_count" "Base packages include matching kernel headers"
  assert_equals "0" "$lts_count" "Base packages exclude LTS kernels"
  assert_equals "1" "$pipewire_count" "GUI packages include PipeWire media support"
  assert_equals "1" "$pulseaudio_count" "GUI packages include PulseAudio"
  assert_equals "0" "$conflicting_audio_count" "GUI packages exclude PulseAudio replacements"
}

test_vbox_packages() {
  local passed=0
  local pkg

  for pkg in "${VBOX_PACKAGES[@]}"; do
    if validate_package_name "$pkg"; then
      ((passed++))
    fi
  done

  assert_equals "${#VBOX_PACKAGES[@]}" "$passed" "All VirtualBox packages have valid names"
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

test_password_hashing_treats_options_as_data() {
  local result

  result=$(hash_password "-stdin")
  assert_contains "$result" "\$6\$" "Option-like passwords are hashed as password data"
}

test_video_driver_validation() {
  assert_command_success "nvidia-open is an allowed video driver" validate_video_driver "nvidia-open"
  assert_command_success "nvidia is an allowed video driver" validate_video_driver "nvidia"
  assert_command_success "Empty video driver is allowed" validate_video_driver ""
  assert_command_fails "Pacstrap options are rejected as video drivers" validate_video_driver "--overwrite"
}

test_swap_size_low_memory() {
  local result

  result=$(calculate_swap_size_gib "$((1 * 1024 * 1024))" "$((32 * 1024 * 1024 * 1024))")
  assert_equals "2" "$result" "Swap is twice RAM on low-memory systems"
}

test_swap_size_matches_midrange_memory() {
  local result

  result=$(calculate_swap_size_gib "$((6 * 1024 * 1024))" "$((32 * 1024 * 1024 * 1024))")
  assert_equals "6" "$result" "Swap matches RAM on midrange systems"
}

test_swap_size_caps_high_memory() {
  local result

  result=$(calculate_swap_size_gib "$((32 * 1024 * 1024))" "$((64 * 1024 * 1024 * 1024))")
  assert_equals "8" "$result" "Swap is capped on high-memory systems"
}

test_swap_size_preserves_root_space() {
  local result

  result=$(calculate_swap_size_gib "$((16 * 1024 * 1024))" "$((12 * 1024 * 1024 * 1024))")
  assert_equals "3" "$result" "Swap shrinks on small disks to preserve root space"
}

test_swap_size_rejects_invalid_inputs() {
  assert_command_fails "Swap sizing rejects zero memory" calculate_swap_size_gib "0" "$((32 * 1024 * 1024 * 1024))"
  assert_command_fails "Swap sizing rejects undersized disks" calculate_swap_size_gib "$((8 * 1024 * 1024))" "$((9 * 1024 * 1024 * 1024))"
}

test_destructive_test_mode_requires_opt_in() {
  local script_path="$SCRIPT_DIR/../install-arch.sh"

  assert_command_fails "Test mode is non-destructive by default" "$script_path" --test-mode
}

test_stdin_execution() {
  local output
  local script_path="$SCRIPT_DIR/../install-arch.sh"

  output=$(
    TEST_MODE_MODE="1" \
    TEST_MODE_HOSTNAME="testhost" \
    TEST_MODE_USER="testuser" \
    TEST_MODE_PASSWORD="testpass" \
    TEST_MODE_DEVICE="/dev/loop0" \
    TEST_MODE_LUKS_PASSWORD="lukspass" \
      bash -s -- --test-mode --dry-run < "$script_path" 2>&1
  )
  assert_contains "$output" "[DRY-RUN]" "Installer supports execution from standard input"
}

run_script_dry_run() {
  local mode="$1"
  local script_path="$SCRIPT_DIR/../install-arch.sh"

  TEST_MODE_MODE="$mode" \
  TEST_MODE_HOSTNAME="testhost" \
  TEST_MODE_USER="testuser" \
  TEST_MODE_PASSWORD="testpass" \
  TEST_MODE_DEVICE="/dev/loop0" \
  TEST_MODE_LUKS_PASSWORD="lukspass" \
  TEST_MODE_MEMORY_KIB="$((6 * 1024 * 1024))" \
  TEST_MODE_DEVICE_SIZE_BYTES="$((32 * 1024 * 1024 * 1024))" \
    "$script_path" --test-mode --dry-run 2>&1
}

test_dry_run_uses_calculated_swap_size() {
  local output

  output=$(run_script_dry_run "1")
  assert_contains "$output" "lvcreate -L 6G volgroup0 -n swap" \
    "Dry run creates swap using the calculated size"
}

# Test 16: Dotfiles bootstrap uses current base profile flow
test_dotfiles_bootstrap_minimal() {
  local output
  local parent_dir_line
  local runuser_line_prefix
  local base_profile_fragment

  output=$(run_script_dry_run "1")
  parent_dir_line="[DRY-RUN] Would execute: arch-chroot /mnt install -d -o testuser -g testuser /home/testuser/src"
  runuser_line_prefix="[DRY-RUN] Would execute: arch-chroot /mnt runuser -u testuser --"
  base_profile_fragment="/home/testuser/src/dotfiles/dotfiles.sh install -p base"
  test_profile_fragment="/home/testuser/src/dotfiles/dotfiles.sh test -p base"

  assert_contains "$output" "$parent_dir_line" \
    "Dotfiles bootstrap creates parent directory"
  assert_contains "$output" "$runuser_line_prefix" \
    "Dotfiles bootstrap runs commands as the target user"
  assert_contains "$output" "HOME=/home/testuser" \
    "Dotfiles bootstrap sets HOME for runuser commands"
  assert_contains "$output" "https://github.com/sneivandt/dotfiles.git" \
    "Dotfiles bootstrap uses the current repo URL"
  assert_contains "$output" "git clone" "Dotfiles bootstrap invokes git clone"
  assert_contains "$output" "/home/testuser/src/dotfiles" \
    "Dotfiles bootstrap clones into the user's src directory"
  assert_occurs_before "$output" "$parent_dir_line" "https://github.com/sneivandt/dotfiles.git" \
    "Dotfiles parent directory is created before cloning"
  assert_contains "$output" "$test_profile_fragment" \
    "Dotfiles profile is validated before install"
  assert_contains "$output" "$base_profile_fragment" \
    "Minimal mode uses the base dotfiles profile"
}

# Test 17: Dotfiles bootstrap uses current desktop profile flow
test_dotfiles_bootstrap_desktop() {
  local output
  local desktop_profile_fragment

  output=$(run_script_dry_run "2")
  desktop_profile_fragment="/home/testuser/src/dotfiles/dotfiles.sh install -p desktop"

  assert_contains "$output" "$desktop_profile_fragment" \
    "Desktop mode uses the desktop dotfiles profile"
}

# Run all tests
test_device_prefix_nvme
test_device_prefix_sata
test_device_prefix_mmc
test_device_prefix_loop
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
test_kernel_and_audio_packages
test_vbox_packages
test_test_mode_vars
test_shebang
test_password_hashing_treats_options_as_data
test_video_driver_validation
test_swap_size_low_memory
test_swap_size_matches_midrange_memory
test_swap_size_caps_high_memory
test_swap_size_preserves_root_space
test_swap_size_rejects_invalid_inputs
test_destructive_test_mode_requires_opt_in
test_stdin_execution
test_dry_run_uses_calculated_swap_size
test_dotfiles_bootstrap_minimal
test_dotfiles_bootstrap_desktop

# Print summary and exit with appropriate code
echo ""
print_test_summary
exit $?
