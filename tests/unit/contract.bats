#!/usr/bin/env bats
# The protocol plugin contract from docs/adding-a-protocol.md, enforced.
#
# Every check loops over scripts/lib/protocol-*.sh, so a new plugin is covered
# the moment it is dropped in - there is nothing to register here.

load ../helpers/load

REQUIRED_FUNCTIONS='proto_validate_args proto_needs_build_openconnect
                    proto_apt_packages proto_write_env_extra
                    proto_connect_snippet proto_version_cmd'

@test "PROTO_NAME matches the filename suffix" {
  local f name
  for f in "${LIB_DIR}"/protocol-*.sh; do
    name="$(basename "$f" .sh)"; name="${name#protocol-}"
    ( source "$f"
      [ "${PROTO_NAME:-}" = "$name" ] ) \
      || fail "$(basename "$f"): PROTO_NAME must be '$name'"
  done
}

@test "every required contract function is defined" {
  local f fn
  for f in "${LIB_DIR}"/protocol-*.sh; do
    for fn in $REQUIRED_FUNCTIONS; do
      ( source "$f"; declare -f "$fn" >/dev/null ) \
        || fail "$(basename "$f"): missing $fn"
    done
  done
}

@test "PROTO_DESC is readable the way --help reads it" {
  # --help extracts this with sed WITHOUT sourcing the file, so the value has to
  # be a single-line double-quoted literal. A multi-line or computed PROTO_DESC
  # would source fine and still come out blank in the protocol list.
  local f desc
  for f in "${LIB_DIR}"/protocol-*.sh; do
    desc="$(sed -n 's/^PROTO_DESC="\(.*\)"[[:space:]]*$/\1/p' "$f" | head -1)"
    [ -n "$desc" ] || fail "$(basename "$f"): PROTO_DESC not extractable by sed"
  done
}

@test "--help lists every protocol with its description" {
  run "$ORCHESTRATOR" --help
  local proto desc
  for proto in $(all_protocols); do
    [[ "$output" == *"$proto"* ]] || fail "--help omits protocol '$proto'"
    desc="$(sed -n 's/^PROTO_DESC="\(.*\)"[[:space:]]*$/\1/p' "${LIB_DIR}/protocol-${proto}.sh" | head -1)"
    [[ "$output" == *"$desc"* ]] || fail "--help omits the description for '$proto'"
  done
}

@test "proto_connect_snippet emits parseable bash" {
  # The snippet is a STRING on the host and is only parsed inside the container,
  # so a syntax error in it survives bash -n and shellcheck on this repo and
  # would first surface during a real connect.
  local f
  for f in "${LIB_DIR}"/protocol-*.sh; do
    ( source "$f"; proto_connect_snippet ) | bash -n /dev/stdin \
      || fail "$(basename "$f"): proto_connect_snippet does not parse"
  done
}

@test "proto_connect_snippet defines proto_connect" {
  local f
  for f in "${LIB_DIR}"/protocol-*.sh; do
    ( source "$f"; proto_connect_snippet ) | grep -q '^proto_connect()' \
      || fail "$(basename "$f"): snippet defines no proto_connect function"
  done
}

@test "proto_connect_snippet does not reference host-only globals" {
  # Host globals like $GATEWAY exist only in the orchestrator. Inside the
  # container the snippet sees /etc/vpn-client.env, so anything it needs must
  # travel through proto_write_env_extra as a VPN_* key.
  local f hit
  for f in "${LIB_DIR}"/protocol-*.sh; do
    hit="$( ( source "$f"; proto_connect_snippet ) \
            | grep -oE '\$\{?(GATEWAY|OVPN|ROUTE_NOPULL|FORTI_USER|FORTI_PORT|ROUTES|PROTOCOL|NAME)\b' || true)"
    [ -z "$hit" ] || fail "$(basename "$f"): snippet uses host-only global(s): $hit"
  done
}

@test "apply_split_routes and wait_for_iface are the only helpers used" {
  # common.sh is copied verbatim into connect-vpn; a snippet calling anything
  # else from the orchestrator would be undefined at runtime.
  local f used known
  known="$( grep -oE '^[a-z_]+\(\)' "${LIB_DIR}/common.sh" | tr -d '()' )"
  for f in "${LIB_DIR}"/protocol-*.sh; do
    for used in $( ( source "$f"; proto_connect_snippet ) \
                   | grep -oE '\b(apply_split_routes|wait_for_iface)\b' | sort -u ); do
      grep -qx "$used" <<<"$known" \
        || fail "$(basename "$f"): calls '$used', which common.sh does not define"
    done
  done
}

@test "proto_apt_packages returns a plain package list" {
  # The orchestrator interpolates this unquoted so it word-splits into apt-get
  # arguments; anything with a shell metacharacter would be a command injection
  # into the container build.
  local f pkgs
  for f in "${LIB_DIR}"/protocol-*.sh; do
    pkgs="$( source "$f"; proto_apt_packages )"
    # Hyphen last so it stays literal; space is intentional (multi-package list).
    [[ "$pkgs" =~ ^[a-zA-Z0-9._+\ -]*$ ]] \
      || fail "$(basename "$f"): proto_apt_packages returned suspicious value: '$pkgs'"
  done
}

@test "proto_needs_build_openconnect returns exactly 0 or 1" {
  local f v
  for f in "${LIB_DIR}"/protocol-*.sh; do
    v="$( source "$f"; proto_needs_build_openconnect )"
    [[ "$v" == "0" || "$v" == "1" ]] \
      || fail "$(basename "$f"): expected 0 or 1, got '$v'"
  done
}

@test "proto_validate_args rejects a missing required argument" {
  # Each plugin must fail loudly rather than build a container that cannot
  # possibly connect. Runs with every orchestrator global empty.
  local f
  for f in "${LIB_DIR}"/protocol-*.sh; do
    run bash -c "GATEWAY='' OVPN='' ROUTE_NOPULL=1; source '$f'; proto_validate_args"
    [ "$status" -ne 0 ] \
      || fail "$(basename "$f"): proto_validate_args accepted an empty configuration"
  done
}

@test "optional hooks, when present, have the right shape" {
  local f iface
  for f in "${LIB_DIR}"/protocol-*.sh; do
    if ( source "$f"; declare -f proto_write_env_interface >/dev/null ); then
      iface="$( source "$f"; proto_write_env_interface )"
      [[ "$iface" =~ ^[a-z0-9]+$ ]] \
        || fail "$(basename "$f"): proto_write_env_interface returned '$iface'"
    fi
  done
}
