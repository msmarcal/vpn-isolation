# shellcheck shell=bash
# A fake `lxc` on PATH, so the orchestrator can be run end to end with no LXD
# daemon, no container, and no root.
#
# Why this exists: create-vpn-lxd-container.sh is, structurally, a program that
# calls `lxc` in a particular order and pipes a generated script into one of
# those calls. Recording the argument list of every call turns "did it configure
# the profile correctly?" into a grep, and capturing the stdin of the
# connect-vpn write gives the tests the REAL generated artifact rather than a
# reimplementation of the assembly logic.
#
# After setup_mock_lxc, two things are available:
#   $LXC_CALLS    - one line per lxc invocation, arguments verbatim
#   $CAPTURE_DIR  - connect-vpn / disconnect-vpn as actually written
#
# The mock returns the exit codes that drive the "nothing exists yet" path:
# absent profile, absent devices, absent container. Tests that need the other
# path set MOCK_PROFILE_EXISTS / MOCK_PPP_MODE before running.

setup_mock_lxc() {
  MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
  LXC_CALLS="${BATS_TEST_TMPDIR}/lxc-calls.txt"
  CAPTURE_DIR="${BATS_TEST_TMPDIR}/captured"
  export MOCK_BIN LXC_CALLS CAPTURE_DIR
  mkdir -p "$MOCK_BIN" "$CAPTURE_DIR"
  : > "$LXC_CALLS"

  cat > "${MOCK_BIN}/lxc" <<'MOCK'
#!/usr/bin/env bash
# Fake lxc. Records the call, then answers just enough for the orchestrator.
printf '%s\n' "$*" >> "$LXC_CALLS"

args="$*"

case "$1" in
  profile)
    case "$2" in
      show)
        # "profile does not exist yet" unless the test says otherwise
        [[ -n "${MOCK_PROFILE_EXISTS:-}" ]] && exit 0
        exit 1
        ;;
      device)
        case "$3" in
          get)
            # $4=profile $5=device $6=key
            if [[ "$5" == "ppp" && "$6" == "mode" && -n "${MOCK_PPP_MODE:-}" ]]; then
              printf '%s\n' "$MOCK_PPP_MODE"
              exit 0
            fi
            # device absent -> orchestrator adds it
            exit 1
            ;;
          *) exit 0 ;;
        esac
        ;;
      *) exit 0 ;;
    esac
    ;;
  info)
    # container must NOT exist, or the orchestrator refuses to continue
    exit 1
    ;;
  list)
    # only used to print the container IP in the final banner
    printf '10.254.2.99 (eth0),\n'
    exit 0
    ;;
  exec)
    # Capture the two generated helper scripts.
    if [[ "$args" == *"/usr/local/bin/connect-vpn"* ]]; then
      cat > "${CAPTURE_DIR}/connect-vpn"
      exit 0
    fi
    if [[ "$args" == *"/usr/local/bin/disconnect-vpn"* ]]; then
      # disconnect-vpn is embedded in the argument, not piped on stdin
      printf '%s\n' "$args" > "${CAPTURE_DIR}/disconnect-vpn.rawargs"
      exit 0
    fi
    # Deliberately NOT draining stdin here. Only the connect-vpn write is piped
    # into, and it is handled above; an unconditional `cat` blocks forever
    # whenever the mock inherits a stdin that never reaches EOF.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCK
  chmod +x "${MOCK_BIN}/lxc"

  # Hermetic HOME: the orchestrator falls back to pushing ~/.ssh/*.pub when no
  # --launchpad-id is given, and tests must not depend on the developer's keys.
  MOCK_HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$MOCK_HOME"
  export HOME="$MOCK_HOME"

  PATH="${MOCK_BIN}:${PATH}"
  export PATH
}

# lxc_called PATTERN - assert some recorded invocation matches PATTERN (grep -E)
lxc_called() {
  grep -qE "$1" "$LXC_CALLS" || {
    echo "expected an lxc call matching: $1"
    echo "actual calls were:"
    sed 's/^/  /' "$LXC_CALLS"
    return 1
  }
}

# lxc_not_called PATTERN - the inverse
lxc_not_called() {
  if grep -qE "$1" "$LXC_CALLS"; then
    echo "did NOT expect an lxc call matching: $1"
    grep -E "$1" "$LXC_CALLS" | sed 's/^/  /'
    return 1
  fi
}

# run_orchestrator PROTOCOL [extra args...] - run a full creation with the mock
run_orchestrator() {
  local proto="$1"; shift
  local -a extra=()
  case "$proto" in
    anyconnect|gp|fortissl) extra=(--gateway vpn.example.com) ;;
    openvpn)
      printf 'client\ndev tun\n' > "${BATS_TEST_TMPDIR}/profile.ovpn"
      extra=(--ovpn "${BATS_TEST_TMPDIR}/profile.ovpn")
      ;;
  esac
  "$ORCHESTRATOR" --name "vpn-test-${proto}" --protocol "$proto" \
    --routes 10.99.0.0/24 "${extra[@]}" "$@"
}
