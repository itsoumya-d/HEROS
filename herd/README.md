# herd — GNAP-style agent coordination for HEROS

`herd` is a small, pure-bash coordination tool that lets multiple HEROS agents
(for example, a **forge** agent and a **ledger** agent) safely agree on who is
doing what — without a daemon, a server, or a large runtime.

It follows the **GNAP** model (Git-Native Agent Protocol,
`github.com/farol-team/gnap`): agents coordinate through plain **JSON files in a
git repository**. State is just files; coordination is just commits.

## Why git-native?

There is **no server**. The coordination state lives entirely in JSON files
under `HERD_DIR` (default `.herd/`):

```
.herd/
├── agents.json              # agent_id -> {name, registered_at, last_heartbeat, status}
├── tasks/
│   ├── deploy-window.json   # {task_id, title, status, claimed_by, created_at, updated_at}
│   └── migrate-db.json
└── .herd-lock               # flock guard for read-modify-write operations
```

`herd.sh` itself **never runs git**. It only reads and writes the JSON files.
The *operator* (a human, a CI job, or a thin wrapper script) is responsible for
`git pull` before reading and `git commit` + `git push` after writing. This
keeps the tool tiny and auditable: every coordination decision is a reviewable,
revertable commit.

Within a single checkout, concurrent invocations are made safe by an exclusive
`flock` on `.herd-lock`. Across machines, git's own merge/push semantics are the
synchronization point — see the workflow below.

## The coordination use case

Suppose the forge agent (database migration safety) and the ledger agent
(accounting) both want to act, but a database migration and a ledger
reconciliation must not run in the same deploy window. They coordinate through a
shared task:

```bash
# Operator creates the coordination task and pushes it.
herd.sh init
herd.sh create-task --task-id deploy-window-2026-06-01 \
                    --title "Exclusive deploy window 2026-06-01"
git add .herd && git commit -m "open deploy window task" && git push

# Both agents register themselves.
herd.sh register-agent --agent-id forge  --name "Forge Agent"
herd.sh register-agent --agent-id ledger --name "Ledger Agent"

# Whoever claims first wins the window. The claim is atomic: if both try,
# exactly one gets the task, the other gets TASK_ALREADY_CLAIMED.
herd.sh claim-task --task-id deploy-window-2026-06-01 --agent-id forge
# -> {"task_id":"deploy-window-2026-06-01","status":"claimed","claimed_by":"forge",...}

herd.sh claim-task --task-id deploy-window-2026-06-01 --agent-id ledger
# -> {"error_code":"TASK_ALREADY_CLAIMED",...}

# Forge does its migration, then completes (only the claimer may complete).
herd.sh complete-task --task-id deploy-window-2026-06-01 --agent-id forge

# If forge decides not to proceed, it releases the window so ledger can take it.
herd.sh release-task --task-id deploy-window-2026-06-01
herd.sh claim-task   --task-id deploy-window-2026-06-01 --agent-id ledger
```

The **atomic claim** is the whole point: two agents must never both believe they
own the same open task.

## Configuration

| Variable   | Default  | Meaning                          |
|------------|----------|----------------------------------|
| `HERD_DIR` | `.herd`  | Directory holding the herd store |

## Commands

All commands print JSON to stdout and **always exit 0**. Errors are reported in
an `error_code` field, never via exit status.

| Command          | Flags                                  | Description |
|------------------|----------------------------------------|-------------|
| `--describe`     | —                                      | Print the full machine-readable descriptor (name, version, commands, flags, error codes, data model). |
| `init`           | —                                      | Create `HERD_DIR`, empty `agents.json` (`{}`), and `tasks/`. Idempotent. |
| `register-agent` | `--agent-id <id> --name <name>`        | Add or refresh an agent. Idempotent; updates `last_heartbeat`. Returns `{agent_id, status:"ok"}`. |
| `heartbeat`      | `--agent-id <id>`                      | Update `last_heartbeat`. Returns `{agent_id, last_heartbeat, status:"ok"}` or `AGENT_NOT_FOUND`. |
| `create-task`    | `--task-id <id> --title <title>`       | Create `tasks/<id>.json` with status `open`. `TASK_EXISTS` if present. Returns the task object. |
| `claim-task`     | `--task-id <id> --agent-id <id>`       | Atomically set `status=claimed`, `claimed_by=agent` **iff** currently `open`. Otherwise `TASK_ALREADY_CLAIMED`. Returns the task. |
| `release-task`   | `--task-id <id>`                       | Set `status` back to `open` and clear `claimed_by`. Returns the task. |
| `complete-task`  | `--task-id <id> --agent-id <id>`       | Set `status=done`. Only the current claimer may complete, else `WRONG_CLAIMER`. Returns the task. |
| `list-tasks`     | `[--status open\|claimed\|done]`       | Print one task object per line (JSONL); empty output if none. |

### Identifier rules

`--agent-id` and `--task-id` must match `^[a-zA-Z0-9_.-]{1,64}$`. This rejects
path separators and `..`, so a task id can never escape the `tasks/` directory.
Free-text fields (`--name`, `--title`) reject control characters and are length
limited.

## Error codes

| Code                   | Meaning |
|------------------------|---------|
| `MISSING_FLAG`         | A required flag was not supplied. |
| `INVALID_INPUT`        | An identifier or field failed validation (charset, length, control chars, path traversal, bad `--status`). |
| `NOT_INITIALIZED`      | `HERD_DIR`/`agents.json` missing; run `init` first. |
| `AGENT_NOT_FOUND`      | Referenced `agent_id` is not registered. |
| `TASK_NOT_FOUND`       | Referenced `task_id` does not exist. |
| `TASK_EXISTS`          | `create-task` for a `task_id` that already exists. |
| `TASK_ALREADY_CLAIMED` | `claim-task` on a task whose status is not `open`. |
| `WRONG_CLAIMER`        | `complete-task` by an agent that is not the current claimer. |
| `STORE_WRITE_FAILED`   | A file or lock operation against the store failed. |

These are also enumerated in `herd.sh --describe`.

## Operator git workflow

`herd.sh` does not touch git. Wrap it so every coordination action is a commit.
A minimal pattern an operator (or CI) can use:

```bash
#!/usr/bin/env bash
set -euo pipefail
# 1. Sync the latest coordination state.
git pull --rebase --autostash

# 2. Perform the herd action.
herd/herd.sh "$@"

# 3. Publish the new state (no-op commit is skipped).
if ! git diff --quiet -- .herd; then
  git add .herd
  git commit -m "herd: $*"
  git push
fi
```

Because every change is a commit, the full coordination history (who claimed
what, when, and who completed it) is auditable in `git log` and revertable.

Conflict handling: if two operators push concurrent claims of the same task,
git rejects the second push. On the next `git pull --rebase`, the loser sees the
task is already `claimed` and a re-run of `claim-task` returns
`TASK_ALREADY_CLAIMED` — the correct outcome.

## Testing

```bash
bash -n herd/herd.sh                                   # syntax check
shellcheck -S warning herd/herd.sh herd/eval-herd.sh   # lint
bash herd/eval-herd.sh                                  # functional + concurrency tests
```

`eval-herd.sh` runs against a throwaway `HERD_DIR`, prints `PASS`/`FAIL` per
case, and exits non-zero on any failure.
