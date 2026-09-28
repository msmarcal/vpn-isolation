#!/usr/bin/env bash
# Run the test suite. With no arguments, runs every tests/t-*.sh; with
# arguments, runs only the ones whose name matches (tests/run.sh routes render).
# Exits non-zero on the first failing file.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
files=()
if (( $# == 0 )); then
  for f in tests/t-*.sh; do files+=("$f"); done
else
  for name in "$@"; do
    f="tests/t-${name}.sh"
    if [[ -f "$f" ]]; then files+=("$f"); else
      echo "no such test: $f" >&2; exit 2
    fi
  done
fi

for f in "${files[@]}"; do
  printf '%s\n' "$(basename "$f")"
  if ! bash "$f"; then
    printf '\n%s failed.\n' "$(basename "$f")" >&2
    exit 1
  fi
done
printf '\nall good.\n'
