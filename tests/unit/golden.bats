#!/usr/bin/env bats
# Golden-file tests for the generated in-container helpers.
#
# connect-vpn is assembled on the host as a string and only ever parsed inside a
# container, so it is the artifact least covered by everything else. These tests
# capture what the orchestrator actually pipes to the container and diff it
# against a committed snapshot - an accidental change to the assembly shows up
# as a readable diff instead of a broken connect weeks later.
#
# To update after an intentional change:  make golden-update

load ../helpers/load
load ../helpers/mock-lxc

setup() {
  setup_mock_lxc
}

# Emit the generated connect-vpn for a protocol on stdout.
generate_connect_vpn() {
  run_orchestrator "$1" >/dev/null 2>&1
  cat "${CAPTURE_DIR}/connect-vpn"
}

@test "generated connect-vpn matches the golden file for every protocol" {
  local proto golden actual
  for proto in $(all_protocols); do
    golden="${GOLDEN_DIR}/connect-vpn.${proto}"
    actual="${BATS_TEST_TMPDIR}/actual.${proto}"
    : > "$LXC_CALLS"; rm -f "${CAPTURE_DIR}/connect-vpn"
    generate_connect_vpn "$proto" > "$actual"

    [ -f "$golden" ] || fail "no golden file for '$proto'. Run: make golden-update"
    diff -u "$golden" "$actual" \
      || fail "generated connect-vpn changed for '$proto' (see diff above). If intended: make golden-update"
  done
}

@test "every generated connect-vpn is valid bash" {
  local proto
  for proto in $(all_protocols); do
    : > "$LXC_CALLS"; rm -f "${CAPTURE_DIR}/connect-vpn"
    generate_connect_vpn "$proto" | bash -n /dev/stdin \
      || fail "generated connect-vpn for '$proto' does not parse"
  done
}

@test "generated connect-vpn carries the shared helpers verbatim" {
  # common.sh is copied, not sourced - the container has no checkout of this
  # repo, so a helper that fails to travel is undefined at connect time.
  local out
  out="$(generate_connect_vpn anyconnect)"
  grep -q '^apply_split_routes()' <<<"$out" || fail "apply_split_routes did not travel"
  grep -q '^wait_for_iface()'    <<<"$out" || fail "wait_for_iface did not travel"
}

@test "generated connect-vpn expands nothing on the host" {
  # The whole point of the quoted heredocs: $VPN_* must survive as literal text
  # and expand inside the container at connect time.
  local out
  out="$(generate_connect_vpn fortissl)"
  grep -q 'VPN_GATEWAY' <<<"$out" || fail "VPN_GATEWAY was expanded away on the host"
}

@test "the already-connected guard covers every client the repo can install" {
  # Guard and teardown must know the same set of binaries, or connect-vpn lets a
  # second tunnel start / disconnect-vpn silently leaves one running.
  local out clients c
  out="$(generate_connect_vpn anyconnect)"
  clients="$(grep -oE 'pgrep -x [a-z]+' <<<"$out" | awk '{print $3}' | sort -u)"
  for c in openconnect openvpn openfortivpn; do
    grep -qx "$c" <<<"$clients" || fail "connect-vpn guard does not check for '$c'"
  done
}

@test "generated disconnect-vpn stops every client the guard knows about" {
  run_orchestrator anyconnect >/dev/null 2>&1
  local raw c
  raw="$(cat "${CAPTURE_DIR}/disconnect-vpn.rawargs")"
  for c in openconnect openvpn openfortivpn; do
    grep -q "pkill -TERM $c" <<<"$raw" || fail "disconnect-vpn never stops '$c'"
  done
}

@test "the three hardcoded client lists stay in sync" {
  # HARDCODED CLIENT LIST (1/2/3) in the orchestrator: the connect-vpn guard,
  # disconnect-vpn, and the sudoers allowlist. Drift between them is the failure
  # mode documented in docs/adding-a-protocol.md.
  run_orchestrator anyconnect --user someuser >/dev/null 2>&1
  local guard teardown sudoers c
  guard="$(grep -oE 'pgrep -x [a-z]+' "${CAPTURE_DIR}/connect-vpn" | awk '{print $3}' | sort -u)"
  teardown="$(cat "${CAPTURE_DIR}/disconnect-vpn.rawargs")"
  sudoers="$(grep -F 'NOPASSWD' "$LXC_CALLS" || true)"

  while read -r c; do
    [ -n "$c" ] || continue
    grep -q "pkill -TERM $c" <<<"$teardown" \
      || fail "client '$c' is guarded in connect-vpn but never stopped by disconnect-vpn"
    grep -q "/$c" <<<"$sudoers" \
      || fail "client '$c' is guarded in connect-vpn but missing from the sudoers allowlist"
  done <<<"$guard"
}

@test "no credentials are written into /etc/vpn-client.env" {
  # Passwords and tokens are prompted for on every connect and must never be
  # persisted; the env file is deliberately mode 0644 on that assumption.
  run_orchestrator fortissl >/dev/null 2>&1
  local envwrite
  envwrite="$(grep -F 'vpn-client.env' "$LXC_CALLS" || true)"
  ! grep -qiE '(VPN_PASSWORD|VPN_FORTI_PASS|_SECRET|_TOKEN)=[^ ]' <<<"$envwrite" \
    || fail "a credential-looking key is being written to /etc/vpn-client.env"
  lxc_called 'chmod 644 /etc/vpn-client.env'
}
