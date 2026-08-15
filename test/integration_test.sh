#!/usr/bin/env bash
# Integration test for install-arch.sh
# 
# Currently validates:
# - Script syntax and executability
# - Command-line flag acceptance (--dry-run, --test-mode)
# - Environment variable handling (TEST_MODE_*)
# - Isolated loop device creation and cleanup
# - Dry-run mode operation without destructive actions
#
# NOTE: This test does not perform actual disk operations. Full installation
# testing would require mocking pacstrap and arch-chroot commands.
#
# Future enhancements could include:
# - Actual partitioning on loop device
# - Mock arch-chroot and pacstrap for complete simulation
# - Verification of partition layout, LUKS, and LVM setup
set -o errexit
set -o nounset
set -o pipefail

# Trap errors with line number
trap 'echo "Error on line $LINENO"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DISK_SIZE="12G"
TEST_DISK_IMAGE=""
TEST_LOOP_DEVICE=""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $*"
}

cleanup() {
  log_info "Cleaning up..."

  if [ -n "$TEST_LOOP_DEVICE" ] && [ -b "$TEST_LOOP_DEVICE" ]; then
    log_info "Detaching loop device $TEST_LOOP_DEVICE"
    losetup -d "$TEST_LOOP_DEVICE" 2>/dev/null || true
  fi

  if [ -n "$TEST_DISK_IMAGE" ] && [ -f "$TEST_DISK_IMAGE" ]; then
    log_info "Removing test disk image"
    rm -f -- "$TEST_DISK_IMAGE"
  fi

  log_info "Cleanup complete"
}

# Set up trap for cleanup
trap cleanup EXIT INT TERM

# Main test function
run_integration_test() {
  log_info "=========================================="
  log_info "Starting Integration Test"
  log_info "=========================================="
  
  # Step 1: Check if running as root
  if [ "$EUID" -ne 0 ]; then
    log_error "Integration tests must be run as root"
    exit 1
  fi
  
  # Step 2: Check for required commands
  log_info "Checking for required commands..."
  local required_cmds=("fallocate" "losetup" "mktemp")
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" > /dev/null; then
      log_error "Required command not found: $cmd"
      exit 1
    fi
  done
  log_success "All required commands available"
  
  # Step 3: Create disk image
  log_info "Creating test disk image ($TEST_DISK_SIZE)..."
  TEST_DISK_IMAGE="$(mktemp /tmp/install-arch-test-disk.XXXXXX.img)"
  if ! fallocate -l "$TEST_DISK_SIZE" "$TEST_DISK_IMAGE"; then
    log_error "Failed to create disk image"
    exit 1
  fi
  log_success "Disk image created: $TEST_DISK_IMAGE"
  
  # Step 4: Set up loop device
  log_info "Setting up loop device..."
  TEST_LOOP_DEVICE=$(losetup -f --show "$TEST_DISK_IMAGE")
  if [ -z "$TEST_LOOP_DEVICE" ]; then
    log_error "Failed to create loop device"
    exit 1
  fi
  log_success "Loop device created: $TEST_LOOP_DEVICE"
  
  # Step 5: Export test mode environment variables
  log_info "Setting up test environment variables..."
  export TEST_MODE_MODE="1"  # Minimal mode
  export TEST_MODE_HOSTNAME="archtest"
  export TEST_MODE_USER="testuser"
  export TEST_MODE_PASSWORD="testpassword123"
  export TEST_MODE_DEVICE="$TEST_LOOP_DEVICE"
  export TEST_MODE_LUKS_PASSWORD="lukspassword123"
  log_success "Environment variables configured"
  
  # Step 6: Run the installer in test mode
  log_info "Running install-arch.sh in test mode..."
  # For now, test that the script accepts the flags without mutating the loop device.
  if ! bash -n "$SCRIPT_DIR/../install-arch.sh"; then
    log_error "Script has syntax errors"
    exit 1
  fi
  log_success "Script syntax check passed"
  
  # Test dry-run mode
  log_info "Testing dry-run mode..."
  local installer_output
  if ! installer_output="$("$SCRIPT_DIR/../install-arch.sh" --dry-run --test-mode 2>&1)"; then
    log_error "Dry-run mode failed"
    printf '%s\n' "$installer_output"
    return 1
  fi
  printf '%s\n' "$installer_output" | sed -n '1,20p'
  if [[ "$installer_output" != *"[DRY-RUN]"* ]]; then
    log_error "Dry-run output did not contain any dry-run actions"
    return 1
  fi
  log_success "Dry-run mode test completed"
  
  log_info "=========================================="
  log_info "Integration Test Complete"
  log_info "=========================================="
  log_success "Basic integration tests passed!"
  log_warning "Full installation test skipped (would require pacstrap and arch-chroot)"
  
  return 0
}

# Run the test
run_integration_test
