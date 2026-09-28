#!/usr/bin/env bash
# The plugin contract. Files are discovered by glob, so this walks whatever is
# in scripts/lib/ rather than a hardcoded list - a new plugin is covered the
# moment it is added.
# Sources are resolved at runtime from REPO_ROOT, which is what lets the suite
# run from anywhere; shellcheck cannot follow that and does not need to.
# shellcheck disable=SC1090,SC1091
set -uo pipefail
source "$(dirname "$0")/lib.sh"

REQUIRED=(
  proto_validate_args proto_needs_build_openconnect proto_apt_packages
  proto_write_env_extra proto_connect_snippet proto_version_cmd
  proto_client_processes proto_sudo_commands
)
OPTIONAL=(proto_post_install proto_write_env_interface proto_disconnect_snippet)

shopt -s nullglob
plugins=("${LIB_DIR}"/protocol-*.sh)
if (( ${#plugins[@]} == 0 )); then
  fail "at least one plugin file exists" "none matched protocol-*.sh"
else pass; fi

for f in "${plugins[@]}"; do
  base="$(basename "$f")"
  name="${base#protocol-}"; name="${name%.sh}"

  # PROTO_DESC is read with sed for --help, never sourced, so it has to be a
  # single-line double-quoted literal.
  desc_line="$(grep -c '^PROTO_DESC="[^"]*"$' "$f" || true)"
  assert_eq "${base}: PROTO_DESC is one double-quoted line" '1' "$desc_line"

  declared="$( ( source "$f" >/dev/null 2>&1; printf '%s' "${PROTO_NAME:-}" ) )"
  assert_eq "${base}: PROTO_NAME matches the filename" "$name" "$declared"

  for fn in "${REQUIRED[@]}"; do
    if ( source "$f" >/dev/null 2>&1; declare -f "$fn" >/dev/null ); then pass
    else fail "${base}: defines ${fn}" "required by the contract"; fi
  done

  # Optional hooks are probed, so their absence is fine - but a hook that IS
  # defined must be a function, not a stray variable.
  for fn in "${OPTIONAL[@]}"; do
    if ( source "$f" >/dev/null 2>&1
         declare -f "$fn" >/dev/null || ! declare -p "$fn" >/dev/null 2>&1 ); then pass
    else fail "${base}: ${fn} is defined but is not a function" ""; fi
  done

  # proto_write_env_extra must emit through env_kv, never a raw heredoc: the
  # file is sourced, so an unquoted value is shell code.
  body="$( ( source "$f" >/dev/null 2>&1; declare -f proto_write_env_extra ) )"
  if [[ -n "$body" ]]; then
    assert_contains "${base}: proto_write_env_extra uses env_kv" "$body" 'env_kv'
  fi

  # Every path in proto_sudo_commands has to be absolute, or sudoers silently
  # fails to match it.
  for cmd in $( ( source "$f" >/dev/null 2>&1; proto_sudo_commands ) ); do
    case "$cmd" in
      /*) pass ;;
      *)  fail "${base}: sudo command is not an absolute path" "$cmd" ;;
    esac
  done

  # proto_client_processes feeds a pgrep -x guard, the default teardown and the
  # connection record's PID lookup, so it must be bare process names.
  for proc in $( ( source "$f" >/dev/null 2>&1; proto_client_processes ) ); do
    case "$proc" in
      */*) fail "${base}: client process must be a bare name, not a path" "$proc" ;;
      "")  fail "${base}: empty client process name" "" ;;
      *)   pass ;;
    esac
  done
done

# --help lists every discovered protocol with its description.
help_out="$("${REPO_ROOT}/scripts/create-vpn-lxd-container.sh" --help 2>&1 || true)"
for f in "${plugins[@]}"; do
  base="$(basename "$f")"; name="${base#protocol-}"; name="${name%.sh}"
  assert_contains "--help lists ${name}" "$help_out" "$name"
done

# An unknown protocol is refused before anything is created.
out="$("${REPO_ROOT}/scripts/create-vpn-lxd-container.sh" --name t --protocol nosuch 2>&1 || true)"
assert_contains "an unknown protocol is refused" "$out" 'unsupported --protocol'
assert_contains "and the available ones are listed" "$out" 'available:'

finish
