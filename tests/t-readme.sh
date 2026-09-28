#!/usr/bin/env bash
# The README, checked against the code it describes.
#
# This exists because the README drifted: a renamed subcommand left it describing
# `connect-vpn`, a command that no longer exists, and the roadmap contradicted the
# body of the same file. Both were found by reading, once, by hand.
#
# What this checks is NAMES: that every flag the README shows is offered by the
# command that owns it, that every `vpn <subcommand>` it shows is one the generated
# command accepts, and that the repo layout matches what git tracks.
#
# What it does NOT check, and must not be mistaken for: prose, whether an
# explanation is still true, the guide, docs/adding-a-protocol.md, or the host
# prerequisites - `modprobe`, `apt` and `lxc network list` all need the host, and
# nothing in this suite may touch it. A green run here does not mean the README is
# accurate. It means nothing in it names something that no longer exists.
#
# SC1090/SC1091: sources are resolved at runtime from REPO_ROOT.
# SC2016: the sed range that finds the layout block is a literal pattern, not a
# string meant to expand - the backticks and $ in it are Markdown, not shell.
# shellcheck disable=SC1090,SC1091,SC2016
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/orchestrator.sh"
use_stubs

# Overridable so the negative cases can be run against a scratch copy: a check
# that is never seen to fail is not known to work.
README_FILE="${README_FILE:-${REPO_ROOT}/README.md}"

# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

# readme_flags - every long flag the README names, from the whole file rather
# than only its command blocks. `--tunnel-mode` and `--auth-mode` are introduced
# in prose, and those are the newest flags and so the likeliest to be renamed.
readme_flags() {
  grep -ohE -- '--[a-z][a-z-]*' "$README_FILE" | sort -u
}

# readme_code - the parts of the README that are commands, which is where a
# subcommand claim lives. Two exclusions, each for its own reason: a fence with
# no language or tagged `text` holds output or a diagram rather than commands,
# and inside a shell block anything after # is a comment. Without the second,
# the layout block's comments offer "vpn command" as a subcommand.
readme_code() {
  local line lang="" in_fence=0 rest
  while IFS= read -r line; do
    if [[ "$line" == '```'* ]]; then
      if (( in_fence )); then in_fence=0; else in_fence=1; lang="${line#\`\`\`}"; fi
      continue
    fi
    if (( in_fence )); then
      case "$lang" in bash|sh|shell) printf '%s\n' "${line%%#*}" ;; esac
    else
      rest="$line"
      while [[ "$rest" == *'`'*'`'* ]]; do
        rest="${rest#*\`}"
        printf '%s\n' "${rest%%\`*}"
        rest="${rest#*\`}"
      done
    fi
  done < "$README_FILE"
}

readme_subcommands() {
  readme_code | grep -ohE '(^|[[:space:]])vpn [a-z][a-z-]*' | awk '{print $2}' | sort -u
}

# ---------------------------------------------------------------------------
# Flags: three owners, declared here
#
# The obvious version of this check - every --flag in the README must appear in
# the orchestrator's --help - fails on four of them, and the tempting repair is a
# skip list. A skip list is what turns this into a rubber stamp: the next flag
# that moves between our two commands would land in it and the failure would read
# as noise. So a flag with no owner is a FAILURE, and adding a flag to the README
# costs one line here. Deliberately.
# ---------------------------------------------------------------------------

declare -A FLAG_OWNER=(
  [--name]=orchestrator [--protocol]=orchestrator [--gateway]=orchestrator
  [--ovpn]=orchestrator [--routes]=orchestrator [--tunnel-mode]=orchestrator
  [--auth-mode]=orchestrator [--user]=orchestrator [--launchpad-id]=orchestrator
  [--build-openconnect]=orchestrator [--refresh-helpers]=orchestrator
  [--sso]=vpn [--native]=vpn [--from-stdin]=vpn
  # Third party. Nothing is asserted about it beyond being declared: an omission
  # is invisible, while a line saying whose flag it is survives being read.
  [--dns]=sshuttle
)

orchestrator_help="$(bash "${REPO_ROOT}/scripts/create-vpn-lxd-container.sh" --help 2>&1)"
assert_contains "the orchestrator prints a usage" "$orchestrator_help" 'Usage:'

vpn_cmd="$(runnable anyconnect)"
vpn_help="$(bash "$vpn_cmd" --help 2>&1)"
assert_contains "the generated vpn prints a usage" "$vpn_help" 'Usage: vpn'

while read -r flag; do
  owner="${FLAG_OWNER[$flag]:-}"
  case "$owner" in
    orchestrator) assert_contains "README's ${flag} is offered by the orchestrator" "$orchestrator_help" "$flag" ;;
    vpn)          assert_contains "README's ${flag} is offered by vpn connect"      "$vpn_help"          "$flag" ;;
    "")           fail "README shows ${flag} and nothing owns it" \
                       "declare it in FLAG_OWNER: orchestrator, vpn, or the third-party tool it belongs to" ;;
    *)            pass ;;  # declared as a third party's flag, by name
  esac
done < <(readme_flags)

# ---------------------------------------------------------------------------
# Subcommands: run them
#
# Not grepped out of `vpn --help`: that text and the dispatcher come from the
# same render_vpn, so comparing them proves only that the file agrees with
# itself - which is exactly what let `connect-vpn` survive in the README.
# Status 2 is the dispatcher saying "no such subcommand".
# ---------------------------------------------------------------------------

# Running a subcommand for real means `connect` authenticates and `disconnect`
# tears down - with every client, `ip`, `sudo` and `pgrep` coming from
# tests/stubs, and the connection record pointed into the sandbox so
# record_connection cannot reach /run on the host.
export VPN_STATE_FILE="${TMPD}/state"

sub_status() {
  ( bash "$vpn_cmd" "$1" >/dev/null 2>&1 )
  printf '%s' "$?"
}

# The meta-check: this is only evidence if a name the dispatcher does not know
# really does come back 2.
assert_eq "an unknown subcommand is status 2" '2' "$(sub_status definitely-not-a-subcommand)"

while read -r sub; do
  st="$(sub_status "$sub")"
  if [[ "$st" == "2" ]]; then
    fail "README shows 'vpn ${sub}' and the command rejects it" \
         "the dispatcher exits 2 for an unknown subcommand - the README is naming something that does not exist"
  else
    pass
  fi
done < <(readme_subcommands)

# These ran for real, so the guard is not "no client started" - `connect` starts
# one by definition. It is that the one which started was the stub: a CLIENT entry
# in the log is the stub saying it intercepted the call, which a real binary on
# PATH would never write.
# The drift this whole file exists for was the README naming `connect-vpn`, and
# the check above would have sailed past it: `connect-vpn` is not of the form
# `vpn <subcommand>`, so there was nothing to extract. Two checks close that.
#
# One: whatever the README runs inside a container has to be the command a
# container actually installs.
while read -r cmd; do
  assert_eq "the README runs '${cmd}' in the container, and containers install 'vpn'" 'vpn' "$cmd"
done < <(readme_code | grep -ohE 'lxc exec [^&|;]*-- [a-z][a-z-]*' | awk '{print $NF}' | sort -u)

# Two: the orchestrator keeps the list of commands it replaced and deletes on
# refresh. Reading it from there rather than naming them here means the next
# rename extends this check by itself.
for gone in "${REPLACED_COMMANDS[@]}"; do
  if grep -qF -- "$gone" "$README_FILE"; then
    fail "the README still mentions ${gone}" \
         "the orchestrator lists it in REPLACED_COMMANDS and deletes it on --refresh-helpers"
  else
    pass
  fi
done

assert_contains "the client that ran was the stub"              "$(stub_log)" 'CLIENT'
assert_contains "the connection record stayed in the sandbox"   "$VPN_STATE_FILE" "$TMPD"
assert_eq       "nothing created /run/vpn-client on this host"   'absent' \
                "$([[ -e /run/vpn-client ]] && echo present || echo absent)"

# ---------------------------------------------------------------------------
# Repo layout, both directions
# ---------------------------------------------------------------------------

# layout_paths - reconstruct each path from the tree diagram. Depth comes from
# counting 4-column indent units, so the box-drawing characters never have to be
# measured. A continuation line carrying only a comment has no entry marker and
# is skipped.
layout_paths() {
  local line body name depth prefix
  local -a stack=()
  while IFS= read -r line; do
    body="${line%%#*}"
    [[ "$body" == *'├── '* || "$body" == *'└── '* ]] || continue
    prefix="${body%%├── *}"
    [[ "$prefix" == "$body" ]] && prefix="${body%%└── *}"
    depth=0
    while [[ "$prefix" == '│   '* || "$prefix" == '    '* ]]; do
      prefix="${prefix:4}"
      depth=$((depth + 1))
    done
    name="${body#*── }"
    name="${name%"${name##*[![:space:]]}"}"
    stack[depth]="${name%/}"
    local path="" i
    for (( i = 0; i <= depth; i++ )); do path="${path}${stack[i]}/"; done
    printf '%s\n' "${path%/}"
  done < <(sed -n '/^```text$/,/^```$/p' "$README_FILE")
}

mapfile -t LAYOUT < <(layout_paths)
assert_eq "the layout block was found and parsed" 'many' "$( (( ${#LAYOUT[@]} > 10 )) && echo many || echo "${#LAYOUT[@]}" )"

mapfile -t TRACKED < <(cd "$REPO_ROOT" && git ls-files)

# Direction one: nothing in the layout is gone from the repo.
for path in "${LAYOUT[@]}"; do
  hit=""
  for t in "${TRACKED[@]}"; do
    if [[ "$t" == "$path" || "$t" == "${path}/"* ]]; then hit=1; break; fi
  done
  if [[ -n "$hit" ]]; then pass; else
    fail "the layout lists ${path}, which git does not track" \
         "either it was deleted and the README still names it, or it was never committed"
  fi
done

# Direction two: nothing tracked is missing from the layout. This is the one that
# would have caught scripts/vpn-sso-login.sh and the whole tests/ tree. A file
# counts as covered when the block names it or any directory above it, because
# stubs/ and fixtures/ are listed as directories rather than file by file.
for t in "${TRACKED[@]}"; do
  case "$t" in docs/*|openspec/*) continue ;; esac
  hit=""
  for path in "${LAYOUT[@]}"; do
    if [[ "$t" == "$path" || "$t" == "${path}/"* ]]; then hit=1; break; fi
  done
  if [[ -n "$hit" ]]; then pass; else
    fail "git tracks ${t} and the README's layout does not mention it" \
         "add it, or a directory that contains it, to the layout block"
  fi
done

finish
