#!/usr/bin/env bash
# Test helper functions for install-arch.sh testing
set -o nounset
set -o pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test result tracking
test_start() {
  local test_name="$1"
  echo -e "${YELLOW}TEST:${NC} $test_name"
  TESTS_RUN=$((TESTS_RUN + 1))
}

test_pass() {
  local test_name="$1"
  echo -e "${GREEN}✓ PASS:${NC} $test_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
  local test_name="$1"
  local reason="${2:-}"
  echo -e "${RED}✗ FAIL:${NC} $test_name"
  if [ -n "$reason" ]; then
    echo -e "  ${RED}Reason:${NC} $reason"
  fi
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Assert functions
assert_equals() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"
  
  test_start "$test_name"
  if [ "$expected" = "$actual" ]; then
    test_pass "$test_name"
    return 0
  else
    test_fail "$test_name" "Expected '$expected', got '$actual'"
    return 1
  fi
}

assert_not_empty() {
  local value="$1"
  local test_name="$2"
  
  test_start "$test_name"
  if [ -n "$value" ]; then
    test_pass "$test_name"
    return 0
  else
    test_fail "$test_name" "Value is empty"
    return 1
  fi
}

assert_empty() {
  local value="$1"
  local test_name="$2"
  
  test_start "$test_name"
  if [ -z "$value" ]; then
    test_pass "$test_name"
    return 0
  else
    test_fail "$test_name" "Expected empty value, got '$value'"
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local test_name="$3"
  
  test_start "$test_name"
  if echo "$haystack" | grep -q "$needle"; then
    test_pass "$test_name"
    return 0
  else
    test_fail "$test_name" "String '$haystack' does not contain '$needle'"
    return 1
  fi
}

assert_file_exists() {
  local file="$1"
  local test_name="$2"
  
  test_start "$test_name"
  if [ -f "$file" ]; then
    test_pass "$test_name"
    return 0
  else
    test_fail "$test_name" "File '$file' does not exist"
    return 1
  fi
}

assert_command_success() {
  local test_name="$1"
  shift
  local cmd=("$@")
  
  test_start "$test_name"
  if "${cmd[@]}" > /dev/null 2>&1; then
    test_pass "$test_name"
    return 0
  else
    test_fail "$test_name" "Command failed: ${cmd[*]}"
    return 1
  fi
}

assert_command_fails() {
  local test_name="$1"
  shift
  local cmd=("$@")
  
  test_start "$test_name"
  if ! "${cmd[@]}" > /dev/null 2>&1; then
    test_pass "$test_name"
    return 0
  else
    test_fail "$test_name" "Command succeeded when it should have failed: ${cmd[*]}"
    return 1
  fi
}

# Print test summary
print_test_summary() {
  echo ""
  echo "========================================"
  echo "Test Summary"
  echo "========================================"
  echo "Tests run:    $TESTS_RUN"
  echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
  echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
  echo "========================================"
  
  if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    return 0
  else
    echo -e "${RED}Some tests failed!${NC}"
    return 1
  fi
}

# Validate package name (check if it would be valid in Arch)
validate_package_name() {
  local pkg="$1"
  # Basic validation: alphanumeric, hyphens, underscores
  if echo "$pkg" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$'; then
    return 0
  else
    return 1
  fi
}

# Test device prefix logic
get_device_prefix() {
  local device="$1"
  local dpfx=""
  case "$device" in
    "/dev/nvme"*) dpfx="p" ;;
  esac
  echo "$dpfx"
}

# Test partition naming
get_partition_name() {
  local device="$1"
  local partition_number="$2"
  local dpfx
  dpfx=$(get_device_prefix "$device")
  echo "$device$dpfx$partition_number"
}

# Validate hostname format
validate_hostname() {
  local hostname="$1"
  # Hostname rules: alphanumeric and hyphens, not starting/ending with hyphen
  if echo "$hostname" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
    return 0
  else
    return 1
  fi
}

# Validate username format
validate_username() {
  local username="$1"
  # Username rules: lowercase alphanumeric, underscores, hyphens, starting with lowercase
  if echo "$username" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'; then
    return 0
  else
    return 1
  fi
}
