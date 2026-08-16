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

test_dialog_dimensions_are_explicit() {
  local dimension

  for dimension in \
    "$DIALOG_MENU_HEIGHT" \
    "$DIALOG_MENU_WIDTH" \
    "$DIALOG_MENU_ROWS" \
    "$DIALOG_INPUT_HEIGHT" \
    "$DIALOG_INPUT_WIDTH" \
    "$DIALOG_CONFIRM_HEIGHT" \
    "$DIALOG_CONFIRM_WIDTH"; do
    if ! [[ "$dimension" =~ ^[1-9][0-9]*$ ]]; then
      test_fail "Dialog dimensions are explicit" "Invalid dimension: $dimension"
      return
    fi
  done

  test_start "Dialog dimensions are explicit"
  test_pass "Dialog dimensions are explicit"
}

test_dialog_uses_explicit_tty_streams() {
  local DEBUG_LOG_PATH
  local TEST_MODE=true
  local input_target
  local output
  local probe_file
  local selected_device=""
  local stderr_target
  local stdout_target
  local terminal_file

  terminal_file="$(mktemp)"
  probe_file="$(mktemp)"
  exec {DIALOG_TTY_FD}<>"$terminal_file"
  DIALOG_PROBE_FILE="$probe_file"

  dialog() {
    local dialog_pid="$BASHPID"
    local input_fd=""
    local input_path
    local output_fd=""
    local stderr_path
    local stdout_path

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --input-fd)
          input_fd="$2"
          shift 2
          ;;
        --output-fd)
          output_fd="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    input_path="$(readlink "/proc/$dialog_pid/fd/$input_fd")"
    stdout_path="$(readlink "/proc/$dialog_pid/fd/1")"
    stderr_path="$(readlink "/proc/$dialog_pid/fd/2")"
    {
      printf 'input=%s\n' "$input_path"
      printf 'stdout=%s\n' "$stdout_path"
      printf 'stderr=%s\n' "$stderr_path"
    } > "$DIALOG_PROBE_FILE"
    printf '/dev/testdisk' >&"$output_fd"
  }

  DEBUG_LOG_PATH="$(mktemp)"
  if ! dialog_capture selected_device "test_disk_selection" "menu" 15 76 6 1 \
    --clear --menu disk 15 76 6 \
    /dev/testdisk 100G </dev/null; then
    unset -f dialog
    close_dialog_tty
    rm -f -- "$terminal_file" "$probe_file" "$DEBUG_LOG_PATH"
    test_start "Dialog capture succeeds with redirected standard input"
    test_fail "Dialog capture succeeds with redirected standard input"
    return
  fi

  unset -f dialog
  close_dialog_tty
  output="$(<"$probe_file")"
  input_target="$(sed -n 's/^input=//p' <<< "$output")"
  stdout_target="$(sed -n 's/^stdout=//p' <<< "$output")"
  stderr_target="$(sed -n 's/^stderr=//p' <<< "$output")"

  assert_equals "/dev/testdisk" "$selected_device" \
    "Dialog result uses a separate captured output descriptor"
  assert_equals "$terminal_file" "$input_target" \
    "Dialog keyboard input uses the dedicated terminal"
  assert_equals "$terminal_file" "$stdout_target" \
    "Dialog display output uses the dedicated terminal"
  assert_equals "$terminal_file" "$stderr_target" \
    "Dialog errors use the dedicated terminal"

  test_start "Dialog invocations avoid non-portable --stdout"
  if grep -q -- '--stdout' "$SCRIPT_DIR/../install-arch.sh"; then
    test_fail "Dialog invocations avoid non-portable --stdout"
  else
    test_pass "Dialog invocations avoid non-portable --stdout"
  fi

  rm -f -- "$terminal_file" "$probe_file" "$DEBUG_LOG_PATH"
}

test_dialog_debug_logging_hides_passwords() {
  local DEBUG_LOG_PATH
  local TEST_MODE=true
  local captured_password=""
  local debug_output
  local secret_value="do-not-log-this-password"
  local terminal_file

  terminal_file="$(mktemp)"
  DEBUG_LOG_PATH="$(mktemp)"
  exec {DIALOG_TTY_FD}<>"$terminal_file"

  dialog() {
    local output_fd=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output-fd)
          output_fd="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf '%s' "$secret_value" >&"$output_fd"
  }

  dialog_capture captured_password "test_password" "passwordbox" 8 50 \
    "not_applicable" "not_applicable" --passwordbox password 8 50
  unset -f dialog
  close_dialog_tty
  debug_output="$(<"$DEBUG_LOG_PATH")"

  assert_not_empty "$captured_password" "Password dialog still captures its output"
  assert_contains "$debug_output" \
    "dialog event=enter name=test_password widget=passwordbox height=8 width=50" \
    "Password dialog entry metadata is logged"
  assert_contains "$debug_output" \
    "dialog event=exit name=test_password widget=passwordbox height=8 width=50" \
    "Password dialog exit metadata is logged"
  assert_contains "$debug_output" "exit_status=0 output=non-empty" \
    "Password dialog logs status and non-empty output state"

  test_start "Password contents are excluded from debug logging"
  if [[ "$debug_output" == *"$secret_value"* ]]; then
    test_fail "Password contents are excluded from debug logging"
  else
    test_pass "Password contents are excluded from debug logging"
  fi

  rm -f -- "$terminal_file" "$DEBUG_LOG_PATH"
}

test_signal_logging_records_active_dialog() {
  local CURRENT_DIALOG_NAME="disk_selection"
  local CURRENT_DIALOG_WIDGET="menu"
  local CURRENT_STAGE="dialog:disk_selection"
  local DEBUG_LOG_PATH
  local DIALOG_ACTIVE=true
  local TEST_MODE=true
  local debug_output
  local signal_status

  DEBUG_LOG_PATH="$(mktemp)"

  (handle_signal INT 130)
  signal_status=$?
  debug_output="$(<"$DEBUG_LOG_PATH")"

  assert_equals "130" "$signal_status" "Signal handler preserves the interrupt exit status"
  assert_contains "$debug_output" "signal event=received signal=INT" \
    "Signal handler records the received signal"
  assert_contains "$debug_output" \
    "stage=dialog:disk_selection dialog_active=true dialog_name=disk_selection widget=menu" \
    "Signal handler records the active dialog and stage"

  rm -f -- "$DEBUG_LOG_PATH"
}

test_cleanup_preserves_debug_log() {
  local DEBUG_LOG_PATH
  local DRY_RUN=true
  local debug_output

  DEBUG_LOG_PATH="$(mktemp)"
  printf 'preserve this diagnostic trace\n' > "$DEBUG_LOG_PATH"
  cleanup
  debug_output="$(<"$DEBUG_LOG_PATH")"

  assert_equals "preserve this diagnostic trace" "$debug_output" \
    "Cleanup preserves the installer debug log"
  rm -f -- "$DEBUG_LOG_PATH"
}

test_stage_logging_preserves_console_output() {
  local DEBUG_LOG_PATH
  local TEST_MODE=true
  local output

  DEBUG_LOG_PATH="$(mktemp)"
  output="$({
    debug_checkpoint "package_installation"
    printf 'package download progress\n'
    printf 'package warning on stderr\n' >&2
    debug_checkpoint "target_system_configuration"
  } 2>&1)"

  assert_contains "$output" "==> Stage: package_installation" \
    "Stage transitions are visible on the console"
  assert_contains "$output" "package download progress" \
    "Stage logging preserves command stdout"
  assert_contains "$output" "package warning on stderr" \
    "Stage logging preserves command stderr"
  assert_occurs_before "$output" "==> Stage: package_installation" \
    "package download progress" \
    "Stage marker precedes command output"
  assert_occurs_before "$output" "package warning on stderr" \
    "==> Stage: target_system_configuration" \
    "Command output precedes the next stage marker"

  rm -f -- "$DEBUG_LOG_PATH"
}

test_installer_does_not_globally_redirect_console_streams() {
  local script_path="$SCRIPT_DIR/../install-arch.sh"

  test_start "Installer keeps normal console streams attached"
  if grep -Eq '^[[:space:]]*exec[[:space:]]+[12]?>' "$script_path"; then
    test_fail "Installer keeps normal console streams attached" \
      "Found a process-wide stdout/stderr file redirection"
  else
    test_pass "Installer keeps normal console streams attached"
  fi
}

test_pacman_keyring_preparation_sequence() {
  local output

  output=$(
    pacman-key() {
      printf 'pacman-key %s\n' "$*"
    }
    pacman() {
      printf 'pacman %s\n' "$*"
    }
    prepare_pacman_keyring
  )

  assert_contains "$output" "pacman-key --init" \
    "Pacman keyring preparation initializes the keyring"
  assert_contains "$output" "pacman-key --populate archlinux" \
    "Pacman keyring preparation populates Arch trusted keys"
  assert_contains "$output" "pacman -Sy --needed --noconfirm archlinux-keyring" \
    "Pacman keyring preparation updates archlinux-keyring"
  assert_occurs_before "$output" "pacman-key --init" "pacman-key --populate archlinux" \
    "Pacman keyring initialization precedes population"
  assert_occurs_before "$output" "pacman-key --populate archlinux" "pacman -Sy --needed --noconfirm archlinux-keyring" \
    "Pacman keyring population precedes package update"
}

test_pacman_keyring_initialization_failure_is_clear() {
  local output
  local status

  output=$(
    exec 2>&1
    pacman-key() {
      return 1
    }
    pacman() {
      return 0
    }
    prepare_pacman_keyring
  )
  status=$?

  assert_equals "1" "$status" "Pacman keyring initialization failure is fatal"
  assert_contains "$output" "Failed to initialize the pacman keyring" \
    "Pacman keyring initialization failure is clear"
}

test_destructive_confirmation_cancel_aborts() {
  local terminal_file

  terminal_file="$(mktemp)"
  test_start "Canceling destructive confirmation aborts"
  if (
    TEST_MODE=false
    DRY_RUN=false
    DIALOG_TTY_FD=""
    exec {DIALOG_TTY_FD}<>"$terminal_file"
    lsblk() {
      printf '/dev/testdisk 100G Test Disk\n'
    }
    dialog() {
      return 1
    }
    confirm_destructive_action /dev/testdisk
  ); then
    test_fail "Canceling destructive confirmation aborts" \
      "Confirmation cancellation returned success"
  else
    test_pass "Canceling destructive confirmation aborts"
  fi
  rm -f -- "$terminal_file"
}

test_cleanup_releases_owned_resources_in_order() {
  local cleanup_log
  local output

  cleanup_log="$(mktemp)"
  if ! (
    DRY_RUN=false
    TEMP_SUDOERS_CREATED=false
    INSTALL_ENABLED_SWAP=true
    INSTALL_MOUNTED_ROOT=true
    INSTALL_CREATED_VG=true
    INSTALL_OPENED_LUKS=true
    DIALOG_TTY_FD=""
    swapoff() {
      printf 'swapoff %s\n' "$*" >> "$cleanup_log"
    }
    mountpoint() {
      return 0
    }
    umount() {
      printf 'umount %s\n' "$*" >> "$cleanup_log"
    }
    vgchange() {
      printf 'vgchange %s\n' "$*" >> "$cleanup_log"
    }
    cryptsetup() {
      printf 'cryptsetup %s\n' "$*" >> "$cleanup_log"
    }
    cleanup
  ); then
    rm -f -- "$cleanup_log"
    test_start "Cleanup releases installer-owned storage resources"
    test_fail "Cleanup releases installer-owned storage resources"
    return
  fi

  output="$(<"$cleanup_log")"
  assert_contains "$output" "swapoff /dev/mapper/volgroup0-swap" \
    "Cleanup disables installer-owned swap"
  assert_contains "$output" "umount -R /mnt" \
    "Cleanup recursively unmounts the installer target"
  assert_contains "$output" "vgchange -an volgroup0" \
    "Cleanup deactivates the installer-owned volume group"
  assert_contains "$output" "cryptsetup close cryptlvm" \
    "Cleanup closes the installer-owned LUKS mapping"
  assert_occurs_before "$output" "swapoff" "umount" \
    "Cleanup disables swap before unmounting"
  assert_occurs_before "$output" "umount" "vgchange" \
    "Cleanup unmounts before deactivating LVM"
  assert_occurs_before "$output" "vgchange" "cryptsetup" \
    "Cleanup deactivates LVM before closing LUKS"

  rm -f -- "$cleanup_log"
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
  parent_dir_line="[DRY-RUN] Would execute: arch-chroot /mnt mkdir -p /home/testuser/src"
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

run_user_account_scenario() (
  local scenario="$1"
  local command_log
  local mock_user_exists=false
  local mock_user_group_exists=false
  local mock_user_uid="1000"
  local mock_user_gid="100"
  local mock_user_home="/srv/testuser"
  local mock_user_shell="/bin/bash"
  local mock_user_groups="users"
  local mock_home_exists=true
  local mock_home_owner="testuser:testuser"

  command_log="$(mktemp)"
  if [ "$scenario" = "fresh" ]; then
    mock_home_exists=false
    mock_home_owner="root:root"
  else
    mock_user_exists=true
    mock_user_group_exists=true
  fi

  DRY_RUN=false
  in_target() {
    printf '%q ' "$@" >> "$command_log"
    printf '\n' >> "$command_log"

    case "$1" in
      getent)
        case "$2:$3" in
          passwd:testuser)
            if [ "$mock_user_exists" = "false" ]; then
              return 2
            fi
            printf 'testuser:x:%s:%s::%s:%s\n' \
              "$mock_user_uid" "$mock_user_gid" "$mock_user_home" "$mock_user_shell"
            ;;
          group:wheel)
            printf 'wheel:x:998:\n'
            ;;
          group:docker)
            printf 'docker:x:971:\n'
            ;;
          group:testuser)
            if [ "$mock_user_group_exists" = "false" ]; then
              return 2
            fi
            printf 'testuser:x:1000:\n'
            ;;
          *)
            return 2
            ;;
        esac
        ;;
      groupadd)
        mock_user_group_exists=true
        ;;
      useradd)
        mock_user_exists=true
        mock_user_group_exists=true
        mock_user_gid="1000"
        mock_user_home="/home/testuser"
        mock_user_shell="/bin/zsh"
        mock_user_groups="testuser docker wheel"
        mock_home_exists=true
        mock_home_owner="testuser:testuser"
        ;;
      usermod)
        mock_user_gid="1000"
        mock_user_home="/home/testuser"
        mock_user_shell="/bin/zsh"
        mock_user_groups="testuser users docker wheel"
        ;;
      test)
        case "$2" in
          -L)
            return 1
            ;;
          -e|-d)
            [ "$mock_home_exists" = "true" ]
            ;;
          *)
            return 2
            ;;
        esac
        ;;
      mkdir)
        mock_home_exists=true
        ;;
      chown)
        if [ "${3:-}" = "/home/testuser" ]; then
          mock_home_owner="testuser:testuser"
        fi
        ;;
      id)
        printf '%s\n' "$mock_user_groups"
        ;;
      stat)
        printf '%s\n' "$mock_home_owner"
        ;;
      *)
        return 2
        ;;
    esac
  }

  ensure_primary_user testuser 'test-password-hash'
  cat "$command_log"
  rm -f -- "$command_log"
)

test_fresh_user_creation() {
  local output

  output="$(run_user_account_scenario fresh)"
  assert_contains "$output" \
    "useradd -mU -G docker\\,wheel -s /bin/zsh -p test-password-hash testuser" \
    "Fresh installation creates the requested user"
  assert_not_contains "$output" "usermod " \
    "Fresh installation does not take the existing-user reconciliation path"
  assert_contains "$output" "stat -c %U:%G /home/testuser" \
    "Fresh user state is verified after creation"
}

test_existing_user_is_reconciled() {
  local output

  output="$(run_user_account_scenario existing)"
  assert_not_contains "$output" "useradd " \
    "Resume does not recreate an existing user"
  assert_contains "$output" \
    "usermod -d /home/testuser -g testuser -aG docker\\,wheel -s /bin/zsh -p test-password-hash testuser" \
    "Resume reconciles home, primary and supplementary groups, shell, and password"
  assert_not_contains "$output" "usermod -m" \
    "Resume does not move or merge existing home contents"
  assert_contains "$output" "stat -c %U:%G /home/testuser" \
    "Existing user state is verified after reconciliation"
}

test_existing_dotfiles_checkout_is_reused() {
  local output

  output="$({
    DRY_RUN=false
    user="testuser"
    in_target() {
      [ "$1" = "test" ] && [ "$2" = "-e" ]
    }
    as_user() {
      case "$*" in
        "git -C /home/testuser/src/dotfiles rev-parse --is-inside-work-tree")
          printf 'true\n'
          ;;
        "git -C /home/testuser/src/dotfiles remote get-url origin")
          printf 'https://github.com/sneivandt/dotfiles.git\n'
          ;;
        *)
          printf 'unexpected as_user command: %s\n' "$*" >&2
          return 2
          ;;
      esac
    }
    prepare_dotfiles_checkout \
      "https://github.com/sneivandt/dotfiles.git" \
      "/home/testuser/src/dotfiles"
  } 2>&1)"

  assert_contains "$output" "Reusing existing dotfiles checkout" \
    "Resume reuses a matching existing dotfiles checkout"
  assert_not_contains "$output" "unexpected as_user command" \
    "Resume does not clone over an existing dotfiles checkout"
}

test_target_failure_reports_operation_and_output() {
  local console_log
  local debug_log_path
  local exit_code
  local output
  local debug_output

  console_log="$(mktemp)"
  debug_log_path="$(mktemp)"
  (
    set -o errexit
    set -o errtrace
    DEBUG_LOG_PATH="$debug_log_path"
    CURRENT_STAGE="target_system_configuration"
    CURRENT_OPERATION="none"
    TEST_MODE=true
    RESUME=false
    # shellcheck disable=SC2329 # Invoked indirectly by run_required_step.
    mocked_target_failure() {
      echo "mock target stdout"
      echo "mock target stderr" >&2
      return 23
    }
    trap error_handler ERR
    run_required_step "arch-chroot /mnt locale-gen" mocked_target_failure
  ) > "$console_log" 2>&1
  exit_code=$?

  output="$(<"$console_log")"
  debug_output="$(<"$debug_log_path")"
  assert_equals "23" "$exit_code" "Target command failure preserves its exit status"
  assert_contains "$output" "mock target stdout" \
    "Target command stdout remains visible on failure"
  assert_contains "$output" "mock target stderr" \
    "Target command stderr remains visible on failure"
  assert_contains "$output" "Stage 'target_system_configuration' failed during 'arch-chroot /mnt locale-gen'" \
    "Target command failure identifies the exact operation"
  assert_contains "$debug_output" "exit_status=23 stage=target_system_configuration" \
    "Target command failure is written to the debug log"
  assert_contains "$debug_output" "operation=arch-chroot /mnt locale-gen" \
    "Debug log identifies the failed target operation"

  rm -f -- "$console_log" "$debug_log_path"
}

test_missing_alsa_control_is_nonfatal() {
  local debug_log_path
  local output

  debug_log_path="$(mktemp)"
  output="$({
    DEBUG_LOG_PATH="$debug_log_path"
    CURRENT_STAGE="target_system_configuration"
    # shellcheck disable=SC2329 # Invoked indirectly by run_optional_step.
    mocked_amixer_failure() {
      echo "amixer: Unable to find simple control 'Master'" >&2
      return 1
    }
    run_optional_step "arch-chroot /mnt amixer -q sset Master 100%" mocked_amixer_failure
    echo "configuration continued"
  } 2>&1)"

  assert_contains "$output" "Unable to find simple control 'Master'" \
    "ALSA failure output remains visible"
  assert_contains "$output" "Optional step failed during arch-chroot /mnt amixer -q sset Master 100%" \
    "Missing ALSA Master control produces a clear warning"
  assert_contains "$output" "configuration continued" \
    "Missing ALSA Master control does not abort configuration"

  rm -f -- "$debug_log_path"
}

test_resume_skips_destructive_and_package_stages() {
  local output
  local script_path="$SCRIPT_DIR/../install-arch.sh"

  output=$(
    TEST_MODE_MODE="2" \
    TEST_MODE_HOSTNAME="testhost" \
    TEST_MODE_USER="testuser" \
    TEST_MODE_PASSWORD="testpass" \
    TEST_MODE_DEVICE="/dev/loop0" \
    TEST_MODE_LUKS_PASSWORD="lukspass" \
      "$script_path" --test-mode --dry-run --resume 2>&1
  )

  assert_contains "$output" "Would validate existing EFI and LUKS partitions" \
    "Resume validates the existing encrypted layout"
  assert_contains "$output" "Would open existing LUKS device /dev/loop0p2 as cryptlvm" \
    "Resume reopens the existing LUKS container"
  assert_contains "$output" "vgchange -ay volgroup0" \
    "Resume activates the existing volume group"
  assert_not_contains "$output" "pacstrap -K" \
    "Resume skips package installation"
  assert_not_contains "$output" "sfdisk --wipe" \
    "Resume skips partitioning"
  assert_not_contains "$output" "cryptsetup luksFormat" \
    "Resume skips LUKS formatting"
  assert_not_contains "$output" "mkfs.ext4" \
    "Resume skips filesystem formatting"
}

test_target_resolv_conf_is_idempotent() {
  local test_root
  local desired_target="/run/systemd/resolve/stub-resolv.conf"
  local link_path
  local original_inode

  test_root="$(mktemp -d)"
  link_path="$test_root/etc/resolv.conf"
  mkdir -p -- "$test_root/etc" "$test_root/run/systemd/resolve"
  touch "$test_root$desired_target"

  configure_target_resolv_conf "$test_root"
  assert_equals "$desired_target" "$(readlink -- "$link_path")" \
    "Missing target resolv.conf is linked to the systemd-resolved stub"

  original_inode="$(stat -c '%i' -- "$link_path")"
  configure_target_resolv_conf "$test_root"
  assert_equals "$original_inode" "$(stat -c '%i' -- "$link_path")" \
    "Correct target resolv.conf link is left unchanged"

  rm -f -- "$link_path"
  ln -s ../run/systemd/resolve/stub-resolv.conf "$link_path"
  original_inode="$(stat -c '%i' -- "$link_path")"
  configure_target_resolv_conf "$test_root"
  assert_equals "$original_inode" "$(stat -c '%i' -- "$link_path")" \
    "Target resolv.conf link resolving to the stub is left unchanged"

  rm -f -- "$link_path"
  ln -s /run/systemd/resolve/resolv.conf "$link_path"
  configure_target_resolv_conf "$test_root"
  assert_equals "$desired_target" "$(readlink -- "$link_path")" \
    "Wrong target resolv.conf link is replaced"

  rm -f -- "$link_path"
  printf 'nameserver 192.0.2.1\n' > "$link_path"
  configure_target_resolv_conf "$test_root"
  assert_equals "$desired_target" "$(readlink -- "$link_path")" \
    "Regular target resolv.conf file is replaced with the desired link"

  rm -r -- "$test_root"
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
test_dialog_dimensions_are_explicit
test_dialog_uses_explicit_tty_streams
test_dialog_debug_logging_hides_passwords
test_signal_logging_records_active_dialog
test_cleanup_preserves_debug_log
test_stage_logging_preserves_console_output
test_installer_does_not_globally_redirect_console_streams
test_pacman_keyring_preparation_sequence
test_pacman_keyring_initialization_failure_is_clear
test_destructive_confirmation_cancel_aborts
test_cleanup_releases_owned_resources_in_order
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
test_fresh_user_creation
test_existing_user_is_reconciled
test_existing_dotfiles_checkout_is_reused
test_target_failure_reports_operation_and_output
test_missing_alsa_control_is_nonfatal
test_resume_skips_destructive_and_package_stages
test_target_resolv_conf_is_idempotent

# Print summary and exit with appropriate code
echo ""
print_test_summary
exit $?
