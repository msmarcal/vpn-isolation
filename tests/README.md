# Tests

```bash
sudo apt install bats shellcheck   # one-time
make test                          # ~6s, no LXD, no root, no network
```

Everything here runs against a **fake `lxc` on `PATH`** (`helpers/mock-lxc.bash`).
The orchestrator is, structurally, a program that calls `lxc` in a particular
order and pipes a generated script into one of those calls, so the mock records
every invocation and captures that pipe. Two consequences worth knowing:

- Assertions are made on the real argument list the script would have sent to
  LXD, not on a reimplementation of its logic.
- The golden files are the **actual** `connect-vpn` the orchestrator writes. The
  captured `connect-vpn.anyconnect` is byte-identical to the one found inside a
  container built for real.

## Layout

| Path | What it covers |
|---|---|
| `unit/lint.bats` | `bash -n`, a shellcheck baseline, and two repo hygiene checks (placeholder hostnames, no tracked secrets) |
| `unit/contract.bats` | The plugin contract from `docs/adding-a-protocol.md`, looped over `scripts/lib/protocol-*.sh` |
| `unit/golden.bats` | The generated `connect-vpn` / `disconnect-vpn`, including drift between the three hardcoded client lists |
| `unit/orchestrator.bats` | Profile setup, argument validation, per-protocol runs |
| `golden/` | Committed snapshots of the generated `connect-vpn`, one per protocol |
| `shellcheck-baseline.txt` | Accepted findings as `file:CODE`, without line numbers. **Currently empty** — `make lint` prints nothing, so anything it does print is new. |

## Adding a protocol

Nothing to register. Every check loops over `scripts/lib/protocol-*.sh`, so a new
plugin is covered the moment the file exists — including a new golden file, which
`make golden-update` creates.

## When a test fails

| Failure | Meaning |
|---|---|
| `generated connect-vpn changed` | The assembly, a snippet, or `common.sh` changed. **Read the diff.** If intended: `make golden-update`. |
| `shellcheck findings changed` | A genuinely new finding — the baseline is empty. Fix it, or add an inline `# shellcheck disable=SCxxxx` with a comment saying why it is intentional. Reach for `make lint-baseline` only when neither is possible. |
| `the three hardcoded client lists stay in sync` | A client is in the `pgrep` guard but missing from `disconnect-vpn` or the sudoers allowlist. See `docs/adding-a-protocol.md`. |
| `PROTO_DESC not extractable by sed` | `--help` reads it without sourcing the file, so it must be a single-line double-quoted literal. |

`make golden-update` and `make lint-baseline` both rubber-stamp whatever the code
currently does. Read the diff they produce before committing it, or they quietly
convert a regression into the new expected behavior.

## What is not covered

No test here connects to a real gateway or starts a container. The suite proves
the orchestrator *builds the right thing*; it cannot prove a tunnel comes up.
That remains a manual step — and per `docs/lxd-vpn-client-containers.md`, never
against the shared `vpn-client` profile: use a throwaway `--profile`.
