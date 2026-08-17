#!/usr/bin/env bash
# Arch Linux semi-interactive installer.
#
# Run from Arch live ISO as root. Collects minimal input (mode, disk, hostname,
# user, passwords) then automates: partitioning, LUKS2 encryption + LVM, base
# package install, optional GUI/workstation stack, user creation, dotfiles, and
# bootloader configuration.
#
# WARNING: Destroys selected disk contents completely.
# Modes:
#   1 Minimal (CLI only)
#   2 Workstation (Wayland + Hyprland + optional NVIDIA)
#   3 VirtualBox Workstation (adds guest utils)
# Installer commands keep their normal terminal stdout/stderr. A separate
# diagnostic trace is available from startup at /tmp/install-arch-debug.log.
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

# Runtime setup

DRY_RUN=false
TEST_MODE=false
RESUME=false
ALLOW_DESTRUCTIVE_TEST_MODE=false
INSTALL_OPENED_LUKS=false
INSTALL_CREATED_VG=false
INSTALL_ENABLED_SWAP=false
INSTALL_MOUNTED_ROOT=false
TEMP_SUDOERS_CREATED=false
DIALOG_TTY_FD=""
DEBUG_LOG_PATH="/tmp/install-arch-debug.log"
CURRENT_STAGE="runtime_setup"
CURRENT_OPERATION="none"
DIALOG_ACTIVE=false
CURRENT_DIALOG_NAME="none"
CURRENT_DIALOG_WIDGET="none"

# Explicit dimensions avoid broken dialog autosizing on the Arch live ISO.
DIALOG_MENU_HEIGHT=15
DIALOG_MENU_WIDTH=76
DIALOG_MENU_ROWS=6
DIALOG_INPUT_HEIGHT=8
DIALOG_INPUT_WIDTH=50
DIALOG_CONFIRM_HEIGHT=13
DIALOG_CONFIRM_WIDTH=76

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --test-mode)
        TEST_MODE=true
        shift
        ;;
      --resume)
        RESUME=true
        shift
        ;;
      --allow-destructive-test-mode)
        ALLOW_DESTRUCTIVE_TEST_MODE=true
        shift
        ;;
      *)
        echo "Unknown option: $1"
        echo "Usage: $0 [--resume] [--dry-run] [--test-mode] [--allow-destructive-test-mode]"
        exit 1
        ;;
    esac
  done
}

debug_log() {
  local timestamp

  printf -v timestamp '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  printf '[%s] %s\n' "$timestamp" "$*" >> "$DEBUG_LOG_PATH" 2>/dev/null || true
}

debug_tty() {
  if [ "$TEST_MODE" = "false" ]; then
    { printf '[install-arch] %s\n' "$*" > /dev/tty; } 2>/dev/null || true
  fi
}

debug_checkpoint() {
  CURRENT_STAGE="$1"
  debug_log "checkpoint stage=$CURRENT_STAGE"
  printf '\n==> Stage: %s\n' "$CURRENT_STAGE"
}

initialize_debug_log() {
  if ! (umask 077 && : > "$DEBUG_LOG_PATH"); then
    echo "Warning: Unable to initialize installer debug log at $DEBUG_LOG_PATH." >&2
    return
  fi
  debug_checkpoint "starting_installer"
}

handle_signal() {
  local signal_name="$1"
  local exit_code="$2"

  debug_log "signal event=received signal=$signal_name stage=$CURRENT_STAGE dialog_active=$DIALOG_ACTIVE dialog_name=$CURRENT_DIALOG_NAME widget=$CURRENT_DIALOG_WIDGET"
  debug_tty "Received $signal_name during stage '$CURRENT_STAGE'; preserving $DEBUG_LOG_PATH"
  exit "$exit_code"
}

error_handler() {
  local exit_code=$?
  local failed_command="$BASH_COMMAND"
  local failed_line="${BASH_LINENO[0]:-$LINENO}"
  local failed_operation="$CURRENT_OPERATION"
  local message

  # Avoid recursively invoking the handler if reporting itself encounters an
  # error. BASH_COMMAND is source text, so variable values such as passwords
  # and passphrases are never expanded into the diagnostic log.
  trap - ERR
  set +o errexit
  if [ "$failed_operation" = "none" ]; then
    failed_operation="$failed_command"
  fi
  message="Error: Stage '$CURRENT_STAGE' failed during '$failed_operation' (line $failed_line, status $exit_code)."
  debug_log "error event=command_failed exit_status=$exit_code stage=$CURRENT_STAGE line=$failed_line operation=$failed_operation command=$failed_command"
  printf '%s\n' "$message" >&2
  printf 'Failing command: %s\n' "$failed_command" >&2
  printf 'Diagnostic log: %s\n' "$DEBUG_LOG_PATH" >&2
  if [ "$CURRENT_STAGE" = "target_system_configuration" ] && [ "$RESUME" = "false" ]; then
    printf 'The installed packages were preserved; rerun with --resume to retry configuration without repartitioning or pacstrap.\n' >&2
  fi
  exit "$exit_code"
}

close_dialog_tty() {
  if [ -n "$DIALOG_TTY_FD" ]; then
    exec {DIALOG_TTY_FD}>&-
    DIALOG_TTY_FD=""
  fi
}

cleanup() {
  close_dialog_tty

  if [ "$DRY_RUN" = "true" ]; then
    return
  fi

  set +o errexit
  # Cleanup is best-effort after a failure. Suppress expected errors from
  # resources that may already have been released, without hiding output from
  # the normal installation commands above.
  if [ "$TEMP_SUDOERS_CREATED" = "true" ] &&
    [ "$INSTALL_MOUNTED_ROOT" = "true" ] &&
    mountpoint -q /mnt 2>/dev/null; then
    rm -f /mnt/etc/sudoers.d/00-installer-wheel-nopasswd
  fi
  if [ "$INSTALL_ENABLED_SWAP" = "true" ]; then
    swapoff /dev/mapper/volgroup0-swap 2>/dev/null || true
  fi
  if [ "$INSTALL_MOUNTED_ROOT" = "true" ] && mountpoint -q /mnt 2>/dev/null; then
    umount -R /mnt 2>/dev/null || true
  fi
  if [ "$INSTALL_CREATED_VG" = "true" ]; then
    vgchange -an volgroup0 2>/dev/null || true
  fi
  if [ "$INSTALL_OPENED_LUKS" = "true" ]; then
    cryptsetup close cryptlvm 2>/dev/null || true
  fi
}

initialize_dialog_tty() {
  if ! exec {DIALOG_TTY_FD}<>/dev/tty; then
    echo "Error: An interactive terminal is required for installer prompts." >&2
    return 1
  fi
}

dialog_capture() {
  local destination_variable="$1"
  local logical_name="$2"
  local widget_type="$3"
  local dialog_height="$4"
  local dialog_width="$5"
  local menu_rows="$6"
  local option_count="$7"
  local dialog_output
  local dialog_status
  local output_state
  shift 7

  if [ -z "$DIALOG_TTY_FD" ]; then
    echo "Error: The installer terminal is not initialized." >&2
    return 1
  fi

  CURRENT_STAGE="dialog:$logical_name"
  DIALOG_ACTIVE=true
  CURRENT_DIALOG_NAME="$logical_name"
  CURRENT_DIALOG_WIDGET="$widget_type"
  debug_log "dialog event=enter name=$logical_name widget=$widget_type height=$dialog_height width=$dialog_width menu_rows=$menu_rows options=$option_count exit_status=not_applicable output=not_applicable"
  debug_tty "Entering $logical_name dialog ($widget_type)"

  if dialog_output="$(
    dialog --input-fd "$DIALOG_TTY_FD" --output-fd 3 "$@" \
      3>&1 \
      1>&"$DIALOG_TTY_FD" \
      2>&"$DIALOG_TTY_FD"
  )"; then
    dialog_status=0
  else
    dialog_status=$?
  fi

  if [ -n "$dialog_output" ]; then
    output_state="non-empty"
  else
    output_state="empty"
  fi
  debug_log "dialog event=exit name=$logical_name widget=$widget_type height=$dialog_height width=$dialog_width menu_rows=$menu_rows options=$option_count exit_status=$dialog_status output=$output_state"
  debug_tty "Exited $logical_name dialog ($widget_type), status $dialog_status, output $output_state"
  DIALOG_ACTIVE=false
  CURRENT_DIALOG_NAME="none"
  CURRENT_DIALOG_WIDGET="none"

  if [ "$dialog_status" -ne 0 ]; then
    # Preserve the wrapper's existing failure contract while retaining the
    # actual dialog status in the diagnostic log.
    return 1
  fi
  printf -v "$destination_variable" '%s' "$dialog_output"
}

dialog_display() {
  local logical_name="$1"
  local widget_type="$2"
  local dialog_height="$3"
  local dialog_width="$4"
  local menu_rows="$5"
  local option_count="$6"
  local dialog_status
  shift 6

  if [ -z "$DIALOG_TTY_FD" ]; then
    echo "Error: The installer terminal is not initialized." >&2
    return 1
  fi

  CURRENT_STAGE="dialog:$logical_name"
  DIALOG_ACTIVE=true
  CURRENT_DIALOG_NAME="$logical_name"
  CURRENT_DIALOG_WIDGET="$widget_type"
  debug_log "dialog event=enter name=$logical_name widget=$widget_type height=$dialog_height width=$dialog_width menu_rows=$menu_rows options=$option_count exit_status=not_applicable output=not_applicable"
  debug_tty "Entering $logical_name dialog ($widget_type)"

  if dialog --input-fd "$DIALOG_TTY_FD" "$@" \
    1>&"$DIALOG_TTY_FD" \
    2>&"$DIALOG_TTY_FD"; then
    dialog_status=0
  else
    dialog_status=$?
  fi

  debug_log "dialog event=exit name=$logical_name widget=$widget_type height=$dialog_height width=$dialog_width menu_rows=$menu_rows options=$option_count exit_status=$dialog_status output=not_applicable"
  debug_tty "Exited $logical_name dialog ($widget_type), status $dialog_status"
  DIALOG_ACTIVE=false
  CURRENT_DIALOG_NAME="none"
  CURRENT_DIALOG_WIDGET="none"
  return "$dialog_status"
}

require_destructive_test_variables() {
  local variable_name
  local required_variables=(
    TEST_MODE_MODE
    TEST_MODE_HOSTNAME
    TEST_MODE_USER
    TEST_MODE_PASSWORD
    TEST_MODE_DEVICE
    TEST_MODE_LUKS_PASSWORD
  )

  for variable_name in "${required_variables[@]}"; do
    if [ -z "${!variable_name:-}" ]; then
      echo "Error: $variable_name must be set for destructive test mode."
      exit 1
    fi
  done
}

prepare_pacman_keyring() {
  if ! command -v pacman-key >/dev/null 2>&1; then
    echo "Error: pacman-key is required to initialize the Arch Linux package keyring." >&2
    return 1
  fi
  if ! command -v pacman >/dev/null 2>&1; then
    echo "Error: pacman is required to update the Arch Linux package keyring." >&2
    return 1
  fi

  if ! pacman-key --init; then
    echo "Error: Failed to initialize the pacman keyring." >&2
    return 1
  fi
  if ! pacman-key --populate archlinux; then
    echo "Error: Failed to populate the pacman keyring with Arch Linux trusted keys." >&2
    return 1
  fi
  if ! pacman -Sy --needed --noconfirm archlinux-keyring; then
    echo "Error: Failed to install or update archlinux-keyring." >&2
    return 1
  fi
}

initialize_runtime() {
  parse_args "$@"

  # Report the failing command and release resources acquired by this run.
  trap error_handler ERR
  trap cleanup EXIT
  trap 'handle_signal INT 130' INT
  trap 'handle_signal TERM 143' TERM
  initialize_debug_log

  if [ "$ALLOW_DESTRUCTIVE_TEST_MODE" = "true" ] &&
    { [ "$TEST_MODE" != "true" ] || [ "$DRY_RUN" = "true" ]; }; then
    echo "Error: --allow-destructive-test-mode requires --test-mode without --dry-run."
    exit 1
  fi

  if [ "$TEST_MODE" = "true" ] && [ "$DRY_RUN" = "false" ]; then
    if [ "$ALLOW_DESTRUCTIVE_TEST_MODE" != "true" ]; then
      echo "Error: --test-mode requires --dry-run unless --allow-destructive-test-mode is explicitly set."
      exit 1
    fi
    require_destructive_test_variables
  fi

  # The interactive path depends on dialog before package installation begins.
  if [ "$TEST_MODE" = "false" ]; then
    if [ "$EUID" -ne 0 ]; then
      echo "Error: This installer must be run as root from the Arch Linux live ISO."
      exit 1
    fi
    if [ "$DRY_RUN" = "false" ] && [ ! -d /sys/firmware/efi/efivars ]; then
      echo "Error: UEFI boot mode is required. Reboot the installer media in UEFI mode."
      exit 1
    fi
    debug_checkpoint "keyring_preparation"
    if ! prepare_pacman_keyring; then
      echo "Error: Pacman keyring preparation failed. Cannot install installer dependencies." >&2
      exit 1
    fi
    debug_checkpoint "dependency_installation"
    if ! pacman -Sy --needed --noconfirm dialog; then
      echo "Error: Failed to install dialog. Cannot proceed with interactive installation."
      echo "Check your internet connection and try again."
      exit 1
    fi
    debug_checkpoint "initializing_dialog_terminal"
    initialize_dialog_tty
    debug_checkpoint "runtime_initialized"
  fi
}

validate_mode() {
  local selected_mode="$1"
  [[ "$selected_mode" =~ ^[1-3]$ ]]
}

validate_hostname() {
  local selected_hostname="$1"
  [[ "$selected_hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

validate_username() {
  local selected_user="$1"
  [[ "$selected_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_package_name() {
  local package_name="$1"
  [[ "$package_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]]
}

validate_video_driver() {
  local selected_driver="$1"
  [ -z "$selected_driver" ] ||
    [ "$selected_driver" = "nvidia-open" ] ||
    [ "$selected_driver" = "nvidia" ]
}

get_device_prefix() {
  local target_device="$1"
  local device_prefix=""

  case "$target_device" in
    "/dev/nvme"*|"/dev/mmcblk"*|"/dev/loop"*) device_prefix="p" ;;
  esac
  printf '%s\n' "$device_prefix"
}

get_partition_name() {
  local target_device="$1"
  local partition_number="$2"
  local device_prefix

  device_prefix="$(get_device_prefix "$target_device")"
  printf '%s%s%s\n' "$target_device" "$device_prefix" "$partition_number"
}

get_total_memory_kib() {
  local memory_kib=""

  if [ "$TEST_MODE" = "true" ] && [ -n "${TEST_MODE_MEMORY_KIB:-}" ]; then
    memory_kib="$TEST_MODE_MEMORY_KIB"
  elif ! memory_kib="$(awk '/^MemTotal:/ { print $2; found=1; exit } END { if (!found) exit 1 }' /proc/meminfo)"; then
    echo "Error: Unable to determine total system memory." >&2
    return 1
  fi

  if ! [[ "$memory_kib" =~ ^[0-9]+$ ]] || [ "$memory_kib" -eq 0 ]; then
    echo "Error: Total system memory must be a positive integer in KiB." >&2
    return 1
  fi

  printf '%s\n' "$memory_kib"
}

get_target_size_bytes() {
  local target_device="$1"
  local size_bytes=""

  if [ "$TEST_MODE" = "true" ] && [ "$DRY_RUN" = "true" ]; then
    size_bytes="${TEST_MODE_DEVICE_SIZE_BYTES:-$((20 * 1024 * 1024 * 1024))}"
  elif [ -b "$target_device" ]; then
    if ! size_bytes="$(blockdev --getsize64 "$target_device")"; then
      echo "Error: Unable to determine the size of target device '$target_device'." >&2
      return 1
    fi
  else
    echo "Error: Unable to determine the size of target device '$target_device'." >&2
    return 1
  fi

  if ! [[ "$size_bytes" =~ ^[0-9]+$ ]] || [ "$size_bytes" -eq 0 ]; then
    echo "Error: Target device size must be a positive integer in bytes." >&2
    return 1
  fi

  printf '%s\n' "$size_bytes"
}

calculate_swap_size_gib() {
  local memory_kib="$1"
  local disk_bytes="$2"
  local gib_kib=$((1024 * 1024))
  local gib_bytes=$((1024 * 1024 * 1024))
  local desired_swap_gib
  local disk_gib
  local max_swap_gib

  if ! [[ "$memory_kib" =~ ^[0-9]+$ ]] || [ "$memory_kib" -eq 0 ]; then
    echo "Error: Memory size must be a positive integer in KiB." >&2
    return 1
  fi
  if ! [[ "$disk_bytes" =~ ^[0-9]+$ ]] || [ "$disk_bytes" -eq 0 ]; then
    echo "Error: Disk size must be a positive integer in bytes." >&2
    return 1
  fi

  if [ "$memory_kib" -le $((2 * gib_kib)) ]; then
    desired_swap_gib=$(((2 * memory_kib + gib_kib - 1) / gib_kib))
  elif [ "$memory_kib" -le $((8 * gib_kib)) ]; then
    desired_swap_gib=$(((memory_kib + gib_kib - 1) / gib_kib))
  else
    desired_swap_gib=8
  fi

  disk_gib=$((disk_bytes / gib_bytes))
  max_swap_gib=$((disk_gib - 9))
  if [ "$max_swap_gib" -lt 1 ]; then
    echo "Error: Target device is too small to allocate swap and preserve at least 8 GiB for root." >&2
    return 1
  fi
  if [ "$desired_swap_gib" -gt "$max_swap_gib" ]; then
    desired_swap_gib="$max_swap_gib"
  fi

  printf '%s\n' "$desired_swap_gib"
}

hash_password() {
  local plaintext_password="$1"
  local password_hash

  if [[ "$plaintext_password" == *$'\n'* || "$plaintext_password" == *$'\r'* ]]; then
    echo "Error: Passwords cannot contain newline characters." >&2
    return 1
  fi

  if ! password_hash="$(printf '%s\n' "$plaintext_password" | openssl passwd -6 -stdin)"; then
    echo "Error: Failed to hash the user password." >&2
    return 1
  fi
  if [[ "$password_hash" != \$6\$* ]] || [ "${#password_hash}" -lt 20 ]; then
    echo "Error: Password hashing returned an invalid SHA-512 hash." >&2
    return 1
  fi

  printf '%s\n' "$password_hash"
}

BASE_PACKAGES=(
  base
  base-devel
  bat
  btop
  ctags
  curl
  dash
  docker
  duf
  efibootmgr
  eza
  fail2ban
  fd
  fzf
  git
  git-delta
  grub
  jq
  lazygit
  linux
  linux-firmware
  linux-headers
  lvm2
  man-db
  man-pages
  networkmanager
  neovim
  openssh
  pacman-contrib
  reflector
  ripgrep
  sed
  shellcheck
  rust
  sudo
  tmux
  ufw
  util-linux
  vim
  wget
  xdg-user-dirs
  zip
  zoxide
  zsh
  zsh-autosuggestions
  zsh-completions
  zsh-syntax-highlighting
)

GUI_PACKAGES=(
  alacritty
  alsa-utils
  chromium
  gammastep
  grim
  hyprland
  hypridle
  hyprlock
  hyprpaper
  mako
  otf-font-awesome
  papirus-icon-theme
  playerctl
  pipewire
  pulseaudio
  qt5-wayland
  qt6-wayland
  slurp
  uwsm
  waybar
  wl-clipboard
  fuzzel
  xorg-xwayland
)

VBOX_PACKAGES=(
  virtualbox-guest-utils
)

# Command helpers keep dry-run output and chroot execution consistent.
run_cmd() {
  if [ "$DRY_RUN" = "true" ]; then
    # Use %q to show a shell-escaped representation of each argument,
    # preserving spaces and special characters.
    printf '[DRY-RUN] Would execute:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run_required_step() {
  local operation="$1"
  shift

  CURRENT_OPERATION="$operation"
  debug_log "command event=start stage=$CURRENT_STAGE operation=$CURRENT_OPERATION"
  "$@"
  debug_log "command event=complete stage=$CURRENT_STAGE operation=$CURRENT_OPERATION"
  CURRENT_OPERATION="none"
}

run_optional_step() {
  local operation="$1"
  shift
  local exit_code

  CURRENT_OPERATION="$operation"
  debug_log "command event=start stage=$CURRENT_STAGE operation=$CURRENT_OPERATION optional=true"
  if "$@"; then
    debug_log "command event=complete stage=$CURRENT_STAGE operation=$CURRENT_OPERATION optional=true"
  else
    exit_code=$?
    debug_log "warning event=optional_command_failed exit_status=$exit_code stage=$CURRENT_STAGE operation=$CURRENT_OPERATION"
    printf 'Warning: Optional step failed during %s (status %s); continuing.\n' \
      "$CURRENT_OPERATION" "$exit_code" >&2
  fi
  CURRENT_OPERATION="none"
}

dry_run_msg() {
  echo "[DRY-RUN] $*"
}

in_target() {
  run_cmd arch-chroot /mnt "$@"
}

as_user() {
  in_target runuser -u "$user" -- env HOME="/home/$user" USER="$user" LOGNAME="$user" "$@"
}

as_user_dotfiles() {
  as_user env DOTFILES_PROVISIONING=arch-chroot "$@"
}

target_group_record() {
  local group_name="$1"

  in_target getent group "$group_name"
}

ensure_target_group() {
  local group_name="$1"
  local group_type="$2"
  local group_record

  if group_record="$(target_group_record "$group_name")"; then
    if [ "${group_record%%:*}" != "$group_name" ]; then
      echo "Error: Target group lookup for '$group_name' returned an unexpected record." >&2
      return 1
    fi
    return
  fi

  echo "Creating missing target group '$group_name'"
  case "$group_type" in
    system)
      in_target groupadd --system "$group_name"
      ;;
    user)
      in_target groupadd "$group_name"
      ;;
    *)
      echo "Error: Unsupported target group type '$group_type'." >&2
      return 1
      ;;
  esac
}

group_list_contains() {
  local group_list="$1"
  local expected_group="$2"

  case " $group_list " in
    *" $expected_group "*) return 0 ;;
    *) return 1 ;;
  esac
}

verify_primary_user() {
  local selected_user="$1"
  local expected_home="/home/$selected_user"
  local account_record
  local account_name
  local account_uid
  local account_gid
  local account_home
  local account_shell
  local primary_group_record
  local primary_group_gid
  local user_groups
  local home_owner

  if ! account_record="$(in_target getent passwd "$selected_user")"; then
    echo "Error: Target user '$selected_user' is missing after account configuration." >&2
    return 1
  fi
  IFS=: read -r account_name _ account_uid account_gid _ account_home account_shell <<< "$account_record"
  if [ "$account_name" != "$selected_user" ] ||
    ! [[ "$account_uid" =~ ^[0-9]+$ ]] || [ "$account_uid" -lt 1000 ]; then
    echo "Error: Target account '$selected_user' is not a suitable regular user." >&2
    return 1
  fi
  if [ "$account_home" != "$expected_home" ] || [ "$account_shell" != "/bin/zsh" ]; then
    echo "Error: Target user '$selected_user' has unexpected home or shell after reconciliation." >&2
    return 1
  fi

  if ! primary_group_record="$(target_group_record "$selected_user")"; then
    echo "Error: Primary group '$selected_user' is missing after account configuration." >&2
    return 1
  fi
  IFS=: read -r _ _ primary_group_gid _ <<< "$primary_group_record"
  if [ "$account_gid" != "$primary_group_gid" ]; then
    echo "Error: Target user '$selected_user' does not use its expected primary group." >&2
    return 1
  fi

  user_groups="$(in_target id -nG "$selected_user")"
  if ! group_list_contains "$user_groups" wheel ||
    ! group_list_contains "$user_groups" docker; then
    echo "Error: Target user '$selected_user' is missing an expected supplementary group." >&2
    return 1
  fi
  if ! in_target test -d "$expected_home"; then
    echo "Error: Expected home directory '$expected_home' is missing." >&2
    return 1
  fi
  home_owner="$(in_target stat -c '%U:%G' "$expected_home")"
  if [ "$home_owner" != "$selected_user:$selected_user" ]; then
    echo "Error: Home directory '$expected_home' is owned by '$home_owner', not '$selected_user:$selected_user'." >&2
    return 1
  fi
}

ensure_primary_user() {
  local selected_user="$1"
  local selected_password_hash="$2"
  local expected_home="/home/$selected_user"
  local account_record

  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would create target user $selected_user if missing, or reconcile the existing account without moving home contents"
    in_target mkdir -p "$expected_home/src"
    in_target chown "$selected_user:$selected_user" "$expected_home" "$expected_home/src"
    return
  fi

  ensure_target_group wheel system
  ensure_target_group docker system

  if account_record="$(in_target getent passwd "$selected_user")"; then
    local account_name
    local account_uid

    IFS=: read -r account_name _ account_uid _ <<< "$account_record"
    if [ "$account_name" != "$selected_user" ] ||
      ! [[ "$account_uid" =~ ^[0-9]+$ ]] || [ "$account_uid" -lt 1000 ]; then
      echo "Error: Existing target account '$selected_user' is not a suitable regular user; refusing to modify it." >&2
      return 1
    fi

    ensure_target_group "$selected_user" user
    echo "Target user '$selected_user' already exists; reconciling account settings"
    # Deliberately omit usermod -m: changing the passwd entry must never move,
    # merge, or overwrite files from an earlier partial installation.
    in_target usermod -d "$expected_home" -g "$selected_user" \
      -aG docker,wheel -s /bin/zsh -p "$selected_password_hash" "$selected_user"
  else
    if target_group_record "$selected_user" >/dev/null 2>&1; then
      in_target useradd -m -g "$selected_user" -G docker,wheel \
        -s /bin/zsh -p "$selected_password_hash" "$selected_user"
    else
      in_target useradd -mU -G docker,wheel -s /bin/zsh \
        -p "$selected_password_hash" "$selected_user"
    fi
  fi

  if in_target test -L "$expected_home"; then
    echo "Error: Expected home path '$expected_home' is a symbolic link; refusing to change its ownership." >&2
    return 1
  elif in_target test -e "$expected_home"; then
    if ! in_target test -d "$expected_home"; then
      echo "Error: Expected home path '$expected_home' exists but is not a directory." >&2
      return 1
    fi
  else
    in_target mkdir -p "$expected_home"
  fi
  in_target chown "$selected_user:$selected_user" "$expected_home"
  in_target mkdir -p "$expected_home/src"
  in_target chown "$selected_user:$selected_user" "$expected_home/src"

  verify_primary_user "$selected_user"
}

prepare_dotfiles_checkout() {
  local repository_url="$1"
  local checkout_dir="$2"
  local checkout_status
  local existing_remote

  if [ "$DRY_RUN" = "true" ]; then
    echo "Cloning dotfiles repository for $user if no checkout exists"
    as_user git clone "$repository_url" "$checkout_dir"
    return
  fi

  if in_target test -e "$checkout_dir/.git"; then
    if ! as_user git -C "$checkout_dir" rev-parse --is-inside-work-tree >/dev/null; then
      echo "Error: Existing dotfiles path '$checkout_dir' is not a usable Git checkout." >&2
      return 1
    fi
    if ! existing_remote="$(as_user git -C "$checkout_dir" remote get-url origin)"; then
      echo "Error: Existing dotfiles checkout '$checkout_dir' has no origin remote." >&2
      return 1
    fi
    if [ "$existing_remote" != "$repository_url" ]; then
      echo "Error: Existing dotfiles checkout '$checkout_dir' uses unexpected origin '$existing_remote'." >&2
      return 1
    fi
    if ! checkout_status="$(as_user git -C "$checkout_dir" status --porcelain)"; then
      echo "Error: Could not inspect existing dotfiles checkout '$checkout_dir'." >&2
      return 1
    fi
    if [ -n "$checkout_status" ]; then
      echo "Error: Existing dotfiles checkout '$checkout_dir' has local changes; refusing to update or overwrite them." >&2
      return 1
    fi
    echo "Updating existing dotfiles checkout at $checkout_dir"
    as_user git -C "$checkout_dir" pull --ff-only
    return
  fi

  if in_target test -e "$checkout_dir"; then
    echo "Error: Dotfiles path '$checkout_dir' already exists but is not a Git checkout; refusing to overwrite it." >&2
    return 1
  fi

  echo "Cloning dotfiles repository for $user"
  as_user git clone "$repository_url" "$checkout_dir"
}

write_file() {
  local path="$1"

  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would write $path"
  else
    mkdir -p "${path%/*}"
    cat > "$path"
  fi
}

append_file() {
  local path="$1"

  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would append to $path"
  else
    mkdir -p "${path%/*}"
    cat >> "$path"
  fi
}

target_symlink_is_correct() {
  local target_root="$1"
  local desired_target="$2"
  local link_path="$3"
  local current_target
  local current_path
  local desired_path

  if [ ! -L "$target_root$link_path" ]; then
    return 1
  fi

  current_target="$(readlink -- "$target_root$link_path")"
  case "$current_target" in
    /*)
      current_path="$target_root$current_target"
      ;;
    *)
      current_path="$target_root${link_path%/*}/$current_target"
      ;;
  esac
  desired_path="$target_root$desired_target"

  [ "$(realpath -ms -- "$current_path")" = "$(realpath -ms -- "$desired_path")" ]
}

ensure_target_symlink() {
  local target_root="$1"
  local desired_target="$2"
  local link_path="$3"

  if [ "$DRY_RUN" = "false" ] &&
    target_symlink_is_correct "$target_root" "$desired_target" "$link_path"; then
    return
  fi

  run_cmd ln -sfnT -- "$desired_target" "$target_root$link_path"
}

configure_target_resolv_conf() {
  local target_root="${1:-/mnt}"

  ensure_target_symlink \
    "$target_root" \
    /run/systemd/resolve/stub-resolv.conf \
    /etc/resolv.conf
}

generate_target_fstab() {
  local fstab_tmp

  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would generate and validate /mnt/etc/fstab"
    return
  fi

  fstab_tmp="$(mktemp /mnt/etc/.fstab.install-arch.XXXXXX)"
  if ! genfstab -U /mnt > "$fstab_tmp"; then
    rm -f -- "$fstab_tmp"
    return 1
  fi
  if ! awk '$2 == "/" { found=1 } END { exit !found }' "$fstab_tmp"; then
    echo "Error: Generated fstab does not contain a root filesystem entry." >&2
    rm -f -- "$fstab_tmp"
    return 1
  fi
  chmod 0644 "$fstab_tmp"
  mv -f -- "$fstab_tmp" /mnt/etc/fstab
}

enable_services() {
  local service

  for service in "$@"; do
    run_required_step "arch-chroot /mnt systemctl enable $service" \
      in_target systemctl enable "$service"
  done
}

configure_target_pacman() {
  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would configure pacman options"
    return
  fi

  if ! grep -Fxq 'Color' /mnt/etc/pacman.conf; then
    sed -i '/^\[options\]/a Color' /mnt/etc/pacman.conf
  fi
  if ! grep -Fxq 'ILoveCandy' /mnt/etc/pacman.conf; then
    sed -i '/^\[options\]/a ILoveCandy' /mnt/etc/pacman.conf
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: Required command not found: $command_name"
    exit 1
  fi
}

run_preflight_checks() {
  local required_commands=(
    arch-chroot
    awk
    blkid
    blockdev
    cryptsetup
    curl
    findmnt
    genfstab
    install
    ln
    lsblk
    lvcreate
    mkfs.ext4
    mkfs.vfat
    mkswap
    mount
    mountpoint
    openssl
    pacman
    pacstrap
    partx
    pvcreate
    readlink
    realpath
    sfdisk
    swapon
    udevadm
    vgchange
    vgcreate
    vgs
    wipefs
  )
  local command_name

  if [ "$DRY_RUN" = "true" ]; then
    return
  fi

  if [ "$EUID" -ne 0 ]; then
    echo "Error: This installer must be run as root."
    exit 1
  fi

  for command_name in "${required_commands[@]}"; do
    require_command "$command_name"
  done

  if mountpoint -q /mnt; then
    echo "Error: /mnt is already mounted. Unmount it before running the installer."
    exit 1
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    if ! timedatectl set-ntp true; then
      echo "Warning: Failed to enable NTP; TLS downloads may fail if system time is wrong." >&2
    fi
  fi

  if ! curl -fsSL --connect-timeout 10 --max-time 20 https://archlinux.org/ >/dev/null; then
    echo "Error: Network check failed. Connect to the internet before running the installer."
    exit 1
  fi
}

validate_target_device() {
  local target_device="$1"
  local device_type
  local min_bytes=$((10 * 1024 * 1024 * 1024))
  local size_bytes

  if [ "$DRY_RUN" = "true" ]; then
    return
  fi

  if [ -z "$target_device" ] || [ ! -b "$target_device" ]; then
    echo "Error: Target device '$target_device' does not exist or is not a block device."
    exit 1
  fi

  device_type="$(lsblk -dn -o TYPE "$target_device")"
  if [ "$device_type" != "disk" ] && [ "$device_type" != "loop" ]; then
    echo "Error: Target device '$target_device' is type '$device_type', not a disk."
    exit 1
  fi

  if lsblk -nr -o MOUNTPOINT "$target_device" | grep -q .; then
    echo "Error: Target device '$target_device' or one of its partitions is mounted."
    exit 1
  fi

  size_bytes="$(blockdev --getsize64 "$target_device")"
  if [ "$size_bytes" -lt "$min_bytes" ]; then
    echo "Error: Target device must be at least 10 GiB."
    exit 1
  fi
}

confirm_destructive_action() {
  local target_device="$1"
  local device_summary

  if [ "$TEST_MODE" = "true" ] || [ "$DRY_RUN" = "true" ]; then
    return
  fi

  device_summary="$(lsblk -dno NAME,SIZE,MODEL "$target_device" | sed 's/[[:space:]]\+/ /g')"
  dialog_display "destructive_confirmation" "yesno" \
    "$DIALOG_CONFIRM_HEIGHT" "$DIALOG_CONFIRM_WIDTH" "not_applicable" "not_applicable" \
    --clear --defaultno --yesno \
    "This will permanently erase all data on:\n\n$device_summary\n\nContinue?" \
    "$DIALOG_CONFIRM_HEIGHT" "$DIALOG_CONFIRM_WIDTH" || exit 1
}

ensure_install_names_available() {
  if [ "$DRY_RUN" = "true" ]; then
    return
  fi

  if [ -e /dev/mapper/cryptlvm ]; then
    echo "Error: /dev/mapper/cryptlvm already exists. Close or rename it before installing."
    exit 1
  fi

  if vgs --noheadings volgroup0 >/dev/null 2>&1; then
    echo "Error: LVM volume group 'volgroup0' already exists. Remove or rename it before installing."
    exit 1
  fi
}

validate_resume_partitions() {
  local efi_partition="$1"
  local luks_partition="$2"
  local efi_type

  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would validate existing EFI and LUKS partitions"
    return
  fi

  if [ ! -b "$efi_partition" ] || [ ! -b "$luks_partition" ]; then
    echo "Error: Resume requires existing EFI and LUKS partitions at '$efi_partition' and '$luks_partition'." >&2
    return 1
  fi
  if ! cryptsetup isLuks "$luks_partition"; then
    echo "Error: Resume refused because '$luks_partition' is not a LUKS container." >&2
    return 1
  fi
  if ! efi_type="$(blkid -s TYPE -o value "$efi_partition")"; then
    efi_type="unknown"
  fi
  if [ "$efi_type" != "vfat" ]; then
    echo "Error: Resume refused because '$efi_partition' is '$efi_type', not vfat." >&2
    return 1
  fi
}

validate_resumed_target() {
  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would validate the existing pacstrap installation"
    return
  fi

  if [ ! -f /mnt/etc/os-release ] ||
    [ ! -x /mnt/usr/bin/bash ] ||
    [ ! -x /mnt/usr/bin/pacman ]; then
    echo "Error: Resume refused because /mnt does not contain a complete Arch base installation." >&2
    return 1
  fi
}

wait_for_block_device() {
  local block_device="$1"
  local attempt

  for ((attempt = 1; attempt <= 10; attempt++)); do
    if [ -b "$block_device" ]; then
      return
    fi
    sleep 1
  done

  echo "Error: Timed out waiting for block device '$block_device'."
  exit 1
}

if [ -n "${BASH_SOURCE[0]:-}" ] && [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

initialize_runtime "$@"
debug_checkpoint "preflight_checks"
run_preflight_checks
debug_checkpoint "preflight_checks_complete"

# Input and validation
# Collect required interactive parameters before mutating system state.

if [ "$TEST_MODE" = "true" ]; then
  mode="${TEST_MODE_MODE:-1}"
else
  debug_checkpoint "collecting_install_mode"
  dialog_capture mode "install_mode" "menu" \
    "$DIALOG_MENU_HEIGHT" "$DIALOG_MENU_WIDTH" "$DIALOG_MENU_ROWS" "3" \
    --clear --menu "Select install mode" \
    "$DIALOG_MENU_HEIGHT" "$DIALOG_MENU_WIDTH" "$DIALOG_MENU_ROWS" \
    "1" "Minimal" "2" "Workstation" "3" "VirtualBox" || exit 1
fi
if ! validate_mode "$mode"; then
  echo "Error: Invalid mode '$mode'. Must be 1, 2, or 3."
  exit 1
fi

if [ "$TEST_MODE" = "true" ]; then
  hostname="${TEST_MODE_HOSTNAME:-testhost}"
else
  debug_checkpoint "collecting_hostname"
  dialog_capture hostname "hostname" "inputbox" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" "not_applicable" "not_applicable" \
    --clear --inputbox "Enter hostname" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" || exit 1
fi
[ -z "$hostname" ] && echo "hostname cannot be empty" && exit 1
hostname="${hostname,,}"
if ! validate_hostname "$hostname"; then
  echo "Error: Invalid hostname '$hostname'. Must be lowercase alphanumeric with optional hyphens, 1-63 characters."
  exit 1
fi

if [ "$TEST_MODE" = "true" ]; then
  user="${TEST_MODE_USER:-testuser}"
else
  debug_checkpoint "collecting_username"
  dialog_capture user "username" "inputbox" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" "not_applicable" "not_applicable" \
    --clear --inputbox "Enter username" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" || exit 1
fi
[ -z "$user" ] && echo "username cannot be empty" && exit 1
if ! validate_username "$user"; then
  echo "Error: Invalid username '$user'. Must start with lowercase letter or underscore, 1-32 characters, lowercase alphanumeric/underscore/hyphen only."
  exit 1
fi

if [ "$TEST_MODE" = "true" ]; then
  password1="${TEST_MODE_PASSWORD:-testpass123}"
  password2="$password1"
else
  debug_checkpoint "collecting_user_password"
  dialog_capture password1 "user_password" "passwordbox" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" "not_applicable" "not_applicable" \
    --clear --insecure --passwordbox "Enter password" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" || exit 1
  dialog_capture password2 "user_password_confirmation" "passwordbox" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" "not_applicable" "not_applicable" \
    --clear --insecure --passwordbox "Enter password again" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" || exit 1
fi
[ -z "$password1" ] && echo "password cannot be empty" && exit 1
if [ "$password1" != "$password2" ]; then echo "Passwords did not match"; exit 1; fi
password_hash=""
if [ "$DRY_RUN" = "false" ]; then
  password_hash="$(hash_password "$password1")"
fi
unset password1 password2

if [ "$TEST_MODE" = "true" ]; then
  device="${TEST_MODE_DEVICE:-/dev/loop0}"
  if [ "$DRY_RUN" = "false" ] && { [ -z "$device" ] || [ ! -b "$device" ]; }; then
    echo "In test mode, device \"$device\" does not exist or is not a block device."
    echo "Set TEST_MODE_DEVICE to a valid block device (for example, a loop device created with losetup)."
    echo "Or use --dry-run mode to skip actual disk operations."
    exit 1
  fi
else
  debug_checkpoint "building_disk_list"
  device_options=()
  while read -r disk_name disk_size; do
    device_options+=( "$disk_name" "$disk_size" )
  done < <(lsblk -dplnx size -o name,size,type | awk '$3 == "disk" { print $1, $2 }' | tac)

  if [ "${#device_options[@]}" -eq 0 ]; then
    echo "Error: No installable disk devices were found."
    exit 1
  fi

  debug_log "disk_options count=$((${#device_options[@]} / 2))"
  for ((option_index = 0; option_index < ${#device_options[@]}; option_index += 2)); do
    printf -v safe_disk_name '%q' "${device_options[option_index]}"
    printf -v safe_disk_size '%q' "${device_options[option_index + 1]}"
    debug_log "disk_option index=$((option_index / 2 + 1)) device=$safe_disk_name size=$safe_disk_size"
  done

  debug_checkpoint "opening_disk_selection_dialog"
  dialog_capture device "disk_selection" "menu" \
    "$DIALOG_MENU_HEIGHT" "$DIALOG_MENU_WIDTH" "$DIALOG_MENU_ROWS" \
    "$((${#device_options[@]} / 2))" \
    --clear --menu "Select installation disk" \
    "$DIALOG_MENU_HEIGHT" "$DIALOG_MENU_WIDTH" "$DIALOG_MENU_ROWS" \
    "${device_options[@]}" || exit 1
  printf -v safe_selected_device '%q' "$device"
  debug_checkpoint "disk_selected"
  debug_log "disk_selection result=$safe_selected_device"
fi
validate_target_device "$device"
if [ "$TEST_MODE" = "true" ] && [ "$DRY_RUN" = "false" ]; then
  if [ "$(lsblk -dn -o TYPE "$device")" != "loop" ]; then
    echo "Error: Destructive test mode only supports loop devices."
    exit 1
  fi
fi
part_efi="$(get_partition_name "$device" 1)"
part_luks="$(get_partition_name "$device" 2)"
if [ "$RESUME" = "true" ]; then
  debug_checkpoint "resume_validation"
  ensure_install_names_available
  validate_resume_partitions "$part_efi" "$part_luks"
else
  debug_checkpoint "destructive_confirmation"
  confirm_destructive_action "$device"
  debug_checkpoint "destructive_confirmation_complete"
  ensure_install_names_available

  debug_checkpoint "calculating_storage_layout"
  total_memory_kib="$(get_total_memory_kib)"
  target_size_bytes="$(get_target_size_bytes "$device")"
  swap_size_gib="$(calculate_swap_size_gib "$total_memory_kib" "$target_size_bytes")"
fi

if [ "$TEST_MODE" = "true" ]; then
  password_luks1="${TEST_MODE_LUKS_PASSWORD:-lukspass123}"
  password_luks2="$password_luks1"
else
  debug_checkpoint "collecting_luks_password"
  dialog_capture password_luks1 "luks_password" "passwordbox" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" "not_applicable" "not_applicable" \
    --clear --insecure --passwordbox "Enter disk encryption password" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" || exit 1
  dialog_capture password_luks2 "luks_password_confirmation" "passwordbox" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" "not_applicable" "not_applicable" \
    --clear --insecure --passwordbox "Enter disk encryption password again" \
    "$DIALOG_INPUT_HEIGHT" "$DIALOG_INPUT_WIDTH" || exit 1
fi
[ -z "$password_luks1" ] && echo "disk encryption password cannot be empty" && exit 1
if [ "$password_luks1" != "$password_luks2" ]; then echo "Passwords did not match"; exit 1; fi

# Only prompt for NVIDIA drivers when hardware is detected in desktop modes.
video_driver=""
if [ "$mode" -eq 2 ] || [ "$mode" -eq 3 ]; then
  debug_checkpoint "detecting_video_driver"
  if [ "$TEST_MODE" = "true" ]; then
    video_driver="${TEST_MODE_VIDEO_DRIVER:-}"
  elif command -v lspci >/dev/null 2>&1 && lspci | grep -e VGA -e 3D | grep -q NVIDIA; then
    dialog_capture video_driver "nvidia_driver" "menu" \
      "$DIALOG_MENU_HEIGHT" "$DIALOG_MENU_WIDTH" "$DIALOG_MENU_ROWS" "3" \
      --clear --menu "NVIDIA GPU detected. Select driver" \
      "$DIALOG_MENU_HEIGHT" "$DIALOG_MENU_WIDTH" "$DIALOG_MENU_ROWS" \
      "nvidia-open" "Open kernel modules (Turing+, recommended)" \
      "nvidia" "Proprietary (pre-Turing GPUs)" \
      "none" "Skip (use nouveau/mesa)" || exit 1
    if [ "$video_driver" = "none" ]; then
      video_driver=""
    fi
  fi
  if ! validate_video_driver "$video_driver"; then
    echo "Error: Invalid video driver '$video_driver'. Expected nvidia-open, nvidia, or an empty value."
    exit 1
  fi
fi

# Prompts are complete; command output now returns to the normal console streams.
debug_checkpoint "interactive_prompts_complete"
close_dialog_tty

# Disk provisioning
# Create a new ESP + LUKS2-on-LVM layout, or reopen the existing layout when
# resuming after pacstrap. Both paths converge before target configuration.

if [ "$RESUME" = "true" ]; then
  debug_checkpoint "resuming_storage"
  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would open existing LUKS device $part_luks as cryptlvm"
  else
    INSTALL_OPENED_LUKS=true
    CURRENT_OPERATION="cryptsetup open $part_luks as cryptlvm (passphrase via stdin)"
    printf '%s' "$password_luks1" | cryptsetup open --key-file - "$part_luks" cryptlvm
    CURRENT_OPERATION="none"
    unset password_luks1 password_luks2
  fi

  if [ "$DRY_RUN" = "false" ]; then
    # Arm cleanup before activation so a partial vgchange is still reversed.
    INSTALL_CREATED_VG=true
  fi
  run_cmd vgchange -ay volgroup0
  if [ "$DRY_RUN" = "false" ] &&
    { [ ! -b /dev/mapper/volgroup0-root ] || [ ! -b /dev/mapper/volgroup0-swap ]; }; then
    echo "Error: Resume requires volgroup0/root and volgroup0/swap logical volumes." >&2
    exit 1
  fi
else
  debug_checkpoint "partitioning"
  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would wipe signatures and create GPT partitions on $device"
  else
    wipefs --all --force "$device"
    sfdisk --wipe always --wipe-partitions always "$device" <<'EOF'
label: gpt

size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
type=CA7D7CCB-63ED-4C53-861C-1742536059CC
EOF
    partx --update "$device"
    udevadm settle
    wait_for_block_device "$part_efi"
    wait_for_block_device "$part_luks"
  fi

  debug_checkpoint "formatting_luks"
  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would encrypt $part_luks with LUKS2"
  else
    CURRENT_OPERATION="cryptsetup luksFormat $part_luks (passphrase via stdin)"
    printf '%s' "$password_luks1" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$part_luks"
    CURRENT_OPERATION="none"
  fi

  debug_checkpoint "opening_luks"
  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would open LUKS device $part_luks as cryptlvm"
  else
    # Arm cleanup before acquisition so partial success is still released.
    INSTALL_OPENED_LUKS=true
    CURRENT_OPERATION="cryptsetup open $part_luks as cryptlvm (passphrase via stdin)"
    printf '%s' "$password_luks1" | cryptsetup open --key-file - "$part_luks" cryptlvm
    CURRENT_OPERATION="none"
    unset password_luks1 password_luks2
  fi

  debug_checkpoint "configuring_lvm"
  run_cmd pvcreate --yes --force /dev/mapper/cryptlvm
  if [ "$DRY_RUN" = "false" ]; then
    # ensure_install_names_available established that this name was unused.
    INSTALL_CREATED_VG=true
  fi
  run_cmd vgcreate volgroup0 /dev/mapper/cryptlvm

  run_cmd lvcreate -L "${swap_size_gib}G" volgroup0 -n swap
  run_cmd lvcreate -l 100%FREE volgroup0 -n root

  debug_checkpoint "formatting_filesystems"
  run_cmd mkswap -f /dev/mapper/volgroup0-swap
  run_cmd mkfs.ext4 -F /dev/mapper/volgroup0-root
  run_cmd mkfs.vfat -F32 -n EFI "$part_efi"
fi

debug_checkpoint "mounting_filesystems"
if [ "$DRY_RUN" = "false" ]; then
  INSTALL_MOUNTED_ROOT=true
fi
run_cmd mount /dev/mapper/volgroup0-root /mnt
if [ "$DRY_RUN" = "false" ]; then
  INSTALL_ENABLED_SWAP=true
fi
run_cmd swapon /dev/mapper/volgroup0-swap
run_cmd mkdir -p /mnt/boot
run_cmd mount "$part_efi" /mnt/boot
if [ "$RESUME" = "true" ]; then
  validate_resumed_target
fi

# Package installation
# Refresh package metadata/keyring, select packages for the chosen mode, then pacstrap.

if [ "$RESUME" = "false" ]; then
  debug_checkpoint "preparing_package_mirrors"
  if [ "$DRY_RUN" = "true" ]; then
    dry_run_msg "Would update mirrorlist"
  else
    mirrorlist_tmp="$(mktemp)"
    curl -fL --show-error --progress-bar \
      'https://archlinux.org/mirrorlist/?country=US&protocol=https&ip_version=4' \
      | sed 's/^#Server/Server/' > "$mirrorlist_tmp"
    if ! grep -q '^Server = ' "$mirrorlist_tmp"; then
      echo "Error: Downloaded mirrorlist did not contain any enabled HTTPS mirrors."
      rm -f "$mirrorlist_tmp"
      exit 1
    fi
    install -m 0644 "$mirrorlist_tmp" /etc/pacman.d/mirrorlist
    rm -f "$mirrorlist_tmp"
  fi

cpu_vendor=""
if [ "$DRY_RUN" = "false" ] && [ "$TEST_MODE" = "false" ]; then
  if grep -q "GenuineIntel" /proc/cpuinfo; then
    cpu_vendor="intel"
  elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    cpu_vendor="amd"
  fi
fi

packages=( "${BASE_PACKAGES[@]}" )
packages_gui=( "${GUI_PACKAGES[@]}" )

# Wayland uses mesa/nouveau by default; add NVIDIA only when explicitly selected.
if [ -n "$video_driver" ]; then
  packages_gui=( "${packages_gui[@]}" "$video_driver" )
fi

packages_vbox=( "${VBOX_PACKAGES[@]}" )

if [ -n "$cpu_vendor" ]; then
  if [ "$cpu_vendor" = "intel" ]; then
    packages=( "${packages[@]}" "intel-ucode" )
  elif [ "$cpu_vendor" = "amd" ]; then
    packages=( "${packages[@]}" "amd-ucode" )
  fi
fi

case "$mode" in
  2)
    packages=( "${packages[@]}" "${packages_gui[@]}" )
    ;;
  3)
    packages=( "${packages[@]}" "${packages_gui[@]}" "${packages_vbox[@]}" )
    ;;
esac

debug_checkpoint "package_installation"
run_cmd pacstrap -K /mnt "${packages[@]}"
fi

# Target system configuration
# Write base OS configuration and enable services before user bootstrap.

debug_checkpoint "target_system_configuration"
run_required_step "generate /mnt/etc/fstab with genfstab -U /mnt" generate_target_fstab

run_required_step "arch-chroot /mnt ln -sfT dash /usr/bin/sh" \
  in_target ln -sfT dash /usr/bin/sh

run_required_step "write /mnt/etc/hostname" write_file /mnt/etc/hostname <<EOF
$hostname
EOF
run_required_step "write /mnt/etc/hosts" write_file /mnt/etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost
::1 localhost.localdomain localhost
127.0.0.1 $hostname.localdomain $hostname
EOF

run_required_step "write /mnt/etc/locale.gen" write_file /mnt/etc/locale.gen <<'EOF'
en_US.UTF-8 UTF-8
EOF
run_required_step "arch-chroot /mnt locale-gen" in_target locale-gen

# NetworkManager delegates DNS to resolved; allow-downgrade avoids strict DNSSEC
# failures on unsigned or misconfigured zones while still validating when possible.
run_required_step "write /mnt/etc/systemd/resolved.conf" \
  write_file /mnt/etc/systemd/resolved.conf <<'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1 1.0.0.1
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
EOF
run_required_step "write /mnt/etc/NetworkManager/conf.d/dns.conf" \
  write_file /mnt/etc/NetworkManager/conf.d/dns.conf <<'EOF'
[main]
dns=systemd-resolved
EOF

# Store an initial ALSA state so desktop sessions start with usable volume.
# amixer's quiet flag intentionally avoids printing an unhelpful mixer dump.
case "$mode" in
  2|3)
    run_optional_step "arch-chroot /mnt amixer -q sset Master 100%" \
      in_target amixer -q sset Master 100%
    run_optional_step "arch-chroot /mnt alsactl store" \
      in_target alsactl store
    ;;
esac

# The installer is opinionated; adjust this before running for other regions.
run_required_step "link /mnt/etc/localtime to US/Pacific timezone" \
  ensure_target_symlink /mnt /usr/share/zoneinfo/US/Pacific /etc/localtime

enable_services \
  NetworkManager.service \
  systemd-resolved.service \
  ufw.service \
  fail2ban.service \
  docker.service \
  systemd-timesyncd.service \
  paccache.timer \
  fstrim.timer \
  reflector.timer

run_required_step "link /mnt/etc/resolv.conf to systemd-resolved stub" \
  configure_target_resolv_conf

run_required_step "arch-chroot /mnt ufw default deny incoming" \
  in_target ufw default deny incoming
run_required_step "arch-chroot /mnt ufw default allow outgoing" \
  in_target ufw default allow outgoing
run_required_step "arch-chroot /mnt ufw --force enable" \
  in_target ufw --force enable

if [ "$mode" -eq 3 ]; then
  enable_services vboxservice.service
fi

# Pacman policy

run_required_step "configure /mnt/etc/pacman.conf options" configure_target_pacman

# Keep /bin/sh pointed at dash even after bash package transactions.
run_required_step "write /mnt/etc/pacman.d/hooks/dash.hook" \
  write_file /mnt/etc/pacman.d/hooks/dash.hook <<'EOF'
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = bash
[Action]
Description = Re-pointing /bin/sh symlink to dash...
When = PostTransaction
Exec = /usr/bin/ln -sfT dash /usr/bin/sh
Depends = dash
EOF

# Retain a small rollback window without letting the package cache grow forever.
run_required_step "write /mnt/etc/pacman.d/hooks/paccache.hook" \
  write_file /mnt/etc/pacman.d/hooks/paccache.hook <<'EOF'
[Trigger]
Operation = Remove
Operation = Install
Operation = Upgrade
Type = Package
Target = *
[Action]
Description = Clean package cache
When = PostTransaction
Exec = /usr/bin/paccache -rk5
Depends = pacman-contrib
EOF

# Hardening and maintenance
# Apply baseline kernel/network hardening plus maintenance service config.

run_required_step "write /mnt/etc/sysctl.d/99-security.conf" \
  write_file /mnt/etc/sysctl.d/99-security.conf <<'EOF'
# Kernel hardening settings for improved security

# Prevent kernel pointer leaks
kernel.kptr_restrict = 2

# Restrict dmesg access to root only
kernel.dmesg_restrict = 1

# Restrict access to kernel logs
kernel.printk = 3 3 3 3

# Protect against SYN flood attacks
net.ipv4.tcp_syncookies = 1

# Disable IP forwarding (unless this machine is a router)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Disable ICMP redirect acceptance
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable secure ICMP redirect acceptance
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Disable ICMP redirect sending
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Enable source address verification without breaking common VPN/multihomed setups
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Ignore ICMP ping requests (optional, uncomment to enable)
# net.ipv4.icmp_echo_ignore_all = 1

# Protect against time-wait assassination
net.ipv4.tcp_rfc1337 = 1

# Increase system file descriptor limit
fs.file-max = 2097152

# Restrict core dumps (potential information leak)
kernel.core_uses_pid = 1
fs.suid_dumpable = 0

# Enable ASLR (Address Space Layout Randomization)
kernel.randomize_va_space = 2
EOF

run_required_step "write /mnt/etc/fail2ban/jail.local" \
  write_file /mnt/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
# Ban hosts for 1 hour (3600 seconds)
bantime = 3600
# Check for attacks within 10 minutes
findtime = 600
# Ban after 5 failed attempts
maxretry = 5
# Use systemd backend for journal-based logging
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
EOF

run_required_step "write /mnt/etc/xdg/reflector/reflector.conf" \
  write_file /mnt/etc/xdg/reflector/reflector.conf <<'EOF'
# Reflector configuration for automatic mirror updates
--save /etc/pacman.d/mirrorlist
--protocol https
--country US
--latest 20
--sort rate
EOF

# Dotfiles bootstrap prerequisites
# Converge and validate AUR build tools inside the target on both fresh and
# resumed installs. Requesting rust explicitly also replaces the conflicting
# rustup proxy package left by older failed installer runs.

debug_checkpoint "dotfiles_bootstrap_prerequisites"
run_required_step \
  "arch-chroot /mnt pacman -Syu --needed --noconfirm base-devel git rust sudo" \
  in_target pacman -Syu --needed --noconfirm base-devel git rust sudo
run_required_step "arch-chroot /mnt cargo --version" in_target cargo --version
run_required_step "arch-chroot /mnt rustc --version" in_target rustc --version

# User and dotfiles
# Create the primary user, temporarily allow sudo for dotfiles, then require sudo passwords.

debug_checkpoint "user_and_dotfiles_configuration"
ensure_primary_user "$user" "$password_hash"
unset password_hash

if [ "$DRY_RUN" = "false" ]; then
  TEMP_SUDOERS_CREATED=true
fi
write_file /mnt/etc/sudoers.d/00-installer-wheel-nopasswd <<'EOF'
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
if [ "$DRY_RUN" = "false" ]; then
  chmod 0440 /mnt/etc/sudoers.d/00-installer-wheel-nopasswd
  in_target visudo -cf /etc/sudoers
fi

in_target passwd -l root
in_target usermod -s /sbin/nologin root

dotfiles_repo="https://github.com/sneivandt/dotfiles.git"
dotfiles_dir="/home/$user/src/dotfiles"
case "$mode" in
  1)
    dotfiles_profile="base"
    ;;
  2|3)
    dotfiles_profile="desktop"
    ;;
esac
echo "Preparing dotfiles bootstrap directory for $user"
prepare_dotfiles_checkout "$dotfiles_repo" "$dotfiles_dir"
echo "Validating dotfiles profile '$dotfiles_profile' for $user"
as_user_dotfiles "$dotfiles_dir/dotfiles.sh" test -p "$dotfiles_profile"
echo "Applying dotfiles profile '$dotfiles_profile' for $user"
as_user_dotfiles "$dotfiles_dir/dotfiles.sh" install -p "$dotfiles_profile" -v

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would remove /mnt/etc/sudoers.d/00-installer-wheel-nopasswd"
else
  rm -f /mnt/etc/sudoers.d/00-installer-wheel-nopasswd
  TEMP_SUDOERS_CREATED=false
fi
write_file /mnt/etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
if [ "$DRY_RUN" = "false" ]; then
  chmod 0440 /mnt/etc/sudoers.d/10-wheel
  in_target visudo -cf /etc/sudoers
fi

# Boot configuration
# Build initramfs images with encryption/LVM hooks and install GRUB for UEFI boot.

debug_checkpoint "boot_configuration"
if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would configure mkinitcpio hooks"
else
  mkinitcpio_hooks="HOOKS=(base udev keyboard keymap consolefont autodetect microcode modconf kms block encrypt lvm2 filesystems fsck)"
  if ! sed -i "s/^HOOKS=.*/$mkinitcpio_hooks/" /mnt/etc/mkinitcpio.conf; then
    echo "Warning: Failed to update mkinitcpio hooks"
  fi
  if ! grep -Fxq "$mkinitcpio_hooks" /mnt/etc/mkinitcpio.conf; then
    echo "Error: mkinitcpio hooks not properly configured. System may not boot with encryption."
    exit 1
  fi
fi
in_target mkinitcpio -p linux

if [ "$DRY_RUN" = "true" ]; then
  dry_run_msg "Would configure GRUB cryptdevice parameter from $part_luks UUID"
else
  crypt_uuid="$(blkid -s UUID -o value "$part_luks")"
  if [ -z "$crypt_uuid" ]; then
    echo "Error: Failed to resolve LUKS partition UUID for GRUB configuration."
    exit 1
  fi
  grub_cmdline="GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$crypt_uuid:cryptlvm root=/dev/mapper/volgroup0-root\""
  if grep -q '^GRUB_CMDLINE_LINUX=' /mnt/etc/default/grub; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|$grub_cmdline|" /mnt/etc/default/grub
  else
    echo "$grub_cmdline" >> /mnt/etc/default/grub
  fi
fi
in_target grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck "$device"
in_target grub-mkconfig -o /boot/grub/grub.cfg

# Cleanup
# Release resources explicitly; the EXIT trap handles failures before this point.
debug_checkpoint "final_cleanup"
run_cmd swapoff /dev/mapper/volgroup0-swap
INSTALL_ENABLED_SWAP=false
run_cmd umount -R /mnt
INSTALL_MOUNTED_ROOT=false
run_cmd vgchange -an volgroup0
INSTALL_CREATED_VG=false
run_cmd cryptsetup close cryptlvm
INSTALL_OPENED_LUKS=false
debug_checkpoint "installer_complete"
