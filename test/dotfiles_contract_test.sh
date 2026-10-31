#!/usr/bin/env bash
# Check production bootstrap arguments against the current released dotfiles CLI.
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install-arch.sh
source "$SCRIPT_DIR/../install-arch.sh"

for tool in gh sha256sum awk; do
  require_command "$tool"
done

case "$(uname -m)" in
  x86_64) asset=dotfiles-linux-x86_64 ;;
  aarch64) asset=dotfiles-linux-aarch64 ;;
  *)
    echo "Error: This contract test requires Linux x86_64 or aarch64." >&2
    exit 1
    ;;
esac

scratch="$(mktemp -d)"
binary="$scratch/$asset"
cleanup_contract() {
  rm -f -- "$binary" "$scratch/checksums.sha256" "$scratch/cli.log"
  rmdir -- "$scratch"
}
trap cleanup_contract EXIT

release="$(gh release view --repo sneivandt/dotfiles --json tagName --jq .tagName)"
gh release download "$release" --repo sneivandt/dotfiles --dir "$scratch" \
  --pattern "$asset" --pattern checksums.sha256
(
  cd "$scratch"
  awk -v asset="$asset" '$2 == asset { print }' checksums.sha256 | sha256sum -c -
)
gh attestation verify "$binary" --repo sneivandt/dotfiles
chmod +x "$binary"

# Help must still reject invalid syntax, or it cannot test the argument contract.
for invalid_args in __invalid_command__ --invalid-option; do
  if HOME="$scratch" "$binary" "$invalid_args" --help > "$scratch/cli.log" 2>&1; then
    echo "Error: CLI help accepted invalid syntax: $invalid_args" >&2
    exit 1
  fi
done

as_user_dotfiles() {
  if [ "$1" != "$scratch/dotfiles.sh" ]; then
    echo "Error: Unexpected dotfiles wrapper path: $1" >&2
    return 1
  fi
  shift
  # Parse the exact production arguments without running checks or provisioning.
  if ! HOME="$scratch" DOTFILES_PROVISIONING=arch-chroot \
    "$binary" "$@" --help > "$scratch/cli.log" 2>&1; then
    cat "$scratch/cli.log" >&2
    return 1
  fi
}

as_user() {
  printf 'Mock target-user command: %s\n' "$*"
}

user=contract-user
for profile in base desktop; do
  provision_dotfiles "$scratch" "$profile"
done
printf 'Dotfiles CLI contract passed against %s; no provisioning was performed.\n' "$release"
