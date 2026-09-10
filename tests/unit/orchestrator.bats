#!/usr/bin/env bats
# Orchestrator behaviour, exercised end to end against a fake lxc.
#
# These assert on the SEQUENCE OF lxc CALLS the script makes, which is the only
# externally visible thing it does. No LXD, no container, no root.

load ../helpers/load
load ../helpers/mock-lxc

setup() {
  setup_mock_lxc
}

@test "runs to completion for every shipped protocol" {
  local proto
  for proto in $(all_protocols); do
    : > "$LXC_CALLS"
    run run_orchestrator "$proto"
    [ "$status" -eq 0 ] || fail "protocol '$proto' exited $status: $output"
  done
}

@test "profile grants /dev/net/tun and /dev/ppp" {
  run_orchestrator anyconnect
  lxc_called 'profile device add vpn-client tun unix-char path=/dev/net/tun'
  lxc_called 'profile device add vpn-client ppp unix-char path=/dev/ppp'
}

@test "/dev/ppp is created 0660, never world-writable" {
  run_orchestrator fortissl
  lxc_called 'ppp unix-char path=/dev/ppp mode=0660'
  lxc_not_called 'mode=0666'
}

@test "an existing profile left at 0666 is tightened to 0660" {
  MOCK_PROFILE_EXISTS=1 MOCK_PPP_MODE=0666 run_orchestrator fortissl
  lxc_called 'profile device set vpn-client ppp mode=0660'
}

@test "a profile already at 0660 is left alone" {
  MOCK_PROFILE_EXISTS=1 MOCK_PPP_MODE=0660 run_orchestrator fortissl
  lxc_not_called 'profile device set vpn-client ppp mode'
}

@test "security.nesting is never enabled" {
  run_orchestrator anyconnect
  lxc_not_called 'security\.nesting'
}

@test "--profile keeps the shared vpn-client profile untouched" {
  run_orchestrator anyconnect --profile throwaway-profile
  lxc_called 'profile create throwaway-profile'
  # Note the anchor: a bare 'vpn-client' also matches /etc/vpn-client.env, which
  # every run writes. Only profile subcommands are of interest here.
  lxc_not_called '^profile .* vpn-client\b'
}

@test "refuses a protocol whose PROTO_NAME disagrees with its filename" {
  local bad="${LIB_DIR}/protocol-zzbadname.sh"
  cat > "$bad" <<'EOF'
# shellcheck shell=bash
PROTO_NAME="something-else"
PROTO_DESC="Temporary fixture"
proto_validate_args() { :; }
proto_needs_build_openconnect() { echo 0; }
proto_apt_packages() { echo ""; }
proto_write_env_extra() { :; }
proto_connect_snippet() { echo 'proto_connect() { :; }'; }
proto_version_cmd() { echo true; }
EOF
  run "$ORCHESTRATOR" --name t --protocol zzbadname
  rm -f "$bad"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PROTO_NAME"* ]] || fail "expected a PROTO_NAME error, got: $output"
  # must bail out before touching lxc at all
  [ ! -s "$LXC_CALLS" ] || fail "orchestrator called lxc before validating: $(cat "$LXC_CALLS")"
}

@test "rejects an unknown protocol" {
  run "$ORCHESTRATOR" --name t --protocol nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported --protocol"* ]]
}

@test "openvpn pushes the profile into the container" {
  run_orchestrator openvpn
  lxc_called 'file push .*profile\.ovpn .*etc/openvpn/client/client\.ovpn'
}
