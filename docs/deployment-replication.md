# Deployment: Durable State Replication

Status: v0.1 wrapper shipped; SQLite path is v0.2 (see `docs/storage-redesign-v2.md`).
Last updated: 2026-05-31.

This guide explains how to make HEROS persisted state durable for production
deployments using [Litestream](https://litestream.io)
([github.com/benbjohnson/litestream](https://github.com/benbjohnson/litestream)),
and what to do **today** while HEROS still stores flat files.

---

## Why

The HEROS `ledger` and `vault` bridges persist state to local disk. Today
that state is **flat-file JSONL**, not SQLite:

- `.ledger-invoices` — append-only invoice/entry log (JSONL)
- `.vault-secrets` — secret store (JSONL)
- `.audit-log` — audit trail (JSONL)

On a single host, that disk is a single point of failure. For production we
want the state continuously copied off-box to object storage (S3/GCS/Azure)
or a remote target (SFTP), so a host loss does not lose committed data and we
can restore quickly.

---

## How Litestream fits

Litestream is a small Go binary that **continuously replicates a SQLite
database** by streaming its write-ahead log (WAL) to a replica destination.
It runs as a sidecar/foreground process. It requires **no application code
changes**: it observes the SQLite WAL and ships frames to the replica. On
disaster, you `litestream restore` the database back from the replica.

Key property: **Litestream replicates SQLite databases, not arbitrary files.**

### Honest caveat — read this first

> HEROS's current on-disk format is **JSONL flat files**
> (`.ledger-invoices`, `.vault-secrets`, `.audit-log`).
> **Litestream cannot replicate those files** — it only understands SQLite
> databases (it streams the SQLite WAL).
>
> Therefore:
> - The `ledger/litestream-replicate.sh` wrapper is shipped **now** and is
>   ready for the **v0.2 SQLite storage backend** described in
>   `docs/storage-redesign-v2.md`. When ledger/vault move to SQLite, point the
>   wrapper at the `.db` file and you get continuous replication.
> - For the **current flat-file format**, use the interim approach below
>   (`aws s3 sync` or `rclone`). Do not expect Litestream to pick up JSONL
>   files; it will not.

---

## Interim: replicating the current JSONL flat files

Until the SQLite backend lands, replicate the flat files on a schedule with a
plain object-storage sync. This is periodic (not continuous), so your recovery
point is bounded by the sync interval.

> **Encrypt secret backups.** `.vault-secrets` is a secret store. Copying it
> to object storage as-is turns the backup bucket into a second plaintext
> secret store. Require encryption-at-rest (SSE-KMS or client-side encryption)
> and give the backup target its own least-privilege access policy — separate
> from the credentials the running service uses.

With the AWS CLI (server-side encryption via a dedicated KMS key):

```bash
# One-shot or via cron / systemd timer (e.g. every 5 minutes).
aws s3 sync /var/lib/heros/ s3://my-bucket/heros-state/ \
  --sse aws:kms \
  --sse-kms-key-id "$HEROS_BACKUP_KMS_KEY_ID" \
  --exclude "*" \
  --include ".ledger-invoices" \
  --include ".vault-secrets" \
  --include ".audit-log"
```

Scope the backup bucket with its own IAM policy (least privilege, write-only
where possible) rather than reusing the replica's runtime credentials.

With [rclone](https://rclone.org) (supports S3, GCS, Azure, SFTP, and more) —
wrap the remote in rclone's `crypt` backend (client-side encryption) or enable
the provider's server-side encryption so `.vault-secrets` is never stored in
the clear:

```bash
# `remote-crypt` is an rclone crypt remote layered over your object store.
rclone sync /var/lib/heros/ remote-crypt:heros-state \
  --include ".ledger-invoices" \
  --include ".vault-secrets" \
  --include ".audit-log"
```

Because the JSONL files are append-only, these syncs are cheap and safe. Pair
with object-storage versioning so a corrupt sync does not clobber good state.

---

## Production (v0.2 SQLite): continuous replication with Litestream

Once ledger/vault persist to a SQLite `.db` file, use the wrapper.

### 1. Install Litestream

```bash
# Linux x64 — see https://litestream.io/install for the current release.
VER=v0.3.13
curl -L -o /tmp/litestream.tar.gz \
  "https://github.com/benbjohnson/litestream/releases/download/${VER}/litestream-${VER}-linux-amd64.tar.gz"
tar -C /usr/local/bin -xzf /tmp/litestream.tar.gz litestream
litestream version
```

Verify the wrapper sees it:

```bash
bash ledger/litestream-replicate.sh check
# => {"available":true,"version":"v0.3.13","path":"/usr/local/bin/litestream","status":"ok"}
```

If Litestream is **not** installed, the wrapper degrades gracefully and exits 0:

```bash
bash ledger/litestream-replicate.sh check
# => {"error_code":"LITESTREAM_NOT_AVAILABLE","retryable":false,"status":"error","available":false}
```

### 2. Configure credentials via environment

Litestream reads backend credentials from the environment. Set the ones for
your backend; do **not** put secrets in the command line.

```bash
# S3 (and S3-compatible: MinIO, R2, Wasabi, ...)
export LITESTREAM_ACCESS_KEY_ID=AKIA...
export LITESTREAM_SECRET_ACCESS_KEY=...

# GCS — use GOOGLE_APPLICATION_CREDENTIALS pointing at a service-account JSON
export GOOGLE_APPLICATION_CREDENTIALS=/etc/heros/gcs-sa.json

# Azure Blob Storage
export LITESTREAM_AZURE_ACCOUNT_NAME=myaccount
export LITESTREAM_AZURE_ACCOUNT_KEY=...
```

### 3. Validate inputs (no replication started)

`validate` is pure and works even without Litestream installed — use it in CI
or pre-flight checks:

```bash
bash ledger/litestream-replicate.sh validate \
  --db /var/lib/heros/.ledger-invoices.db \
  --replica s3://my-bucket/ledger
# => {"valid":true,"db":"...","replica_scheme":"s3","status":"ok"}
```

### 4. Start continuous replication

`replicate` is a long-running **foreground** process. Run it under a process
supervisor (systemd, runit, a container entrypoint, etc.):

```bash
bash ledger/litestream-replicate.sh replicate \
  --db /var/lib/heros/.ledger-invoices.db \
  --replica s3://my-bucket/ledger
```

Example systemd unit:

```ini
[Unit]
Description=HEROS ledger Litestream replication
After=network-online.target

[Service]
EnvironmentFile=/etc/heros/litestream.env
ExecStart=/usr/bin/bash /opt/heros/ledger/litestream-replicate.sh replicate \
  --db /var/lib/heros/.ledger-invoices.db \
  --replica s3://my-bucket/ledger
Restart=always

[Install]
WantedBy=multi-user.target
```

---

## Disaster recovery: restore

To rebuild the database on a fresh host from the replica:

```bash
# Restores to the path given with --db from the replica.
bash ledger/litestream-replicate.sh restore \
  --db /var/lib/heros/.ledger-invoices.db \
  --replica s3://my-bucket/ledger
```

This runs `litestream restore -o <db> <replica>`. Restore **before** starting
the ledger/vault service, and **before** starting the `replicate` process for
the restored database. Then bring the service up and re-start replication.

For the interim JSONL approach, recovery is the inverse of the sync:

```bash
aws s3 sync s3://my-bucket/heros-state/ /var/lib/heros/
# or: rclone sync remote:my-bucket/heros-state /var/lib/heros/
```

---

## Supported backends

The wrapper validates these replica URL schemes (`validate` /
`--describe` list them), each mapping to a Litestream backend:

| Scheme    | Backend                          | Example replica URL                       |
|-----------|----------------------------------|-------------------------------------------|
| `s3://`   | Amazon S3 / S3-compatible        | `s3://my-bucket/ledger`                   |
| `gcs://`  | Google Cloud Storage             | `gcs://my-bucket/ledger`                  |
| `abs://`  | Azure Blob Storage               | `abs://my-container/ledger`               |
| `sftp://` | SFTP server                      | `sftp://host:22/srv/backups/ledger`       |
| `file://` | Local / mounted path             | `file:///mnt/backups/ledger`              |

S3-compatible stores (MinIO, Cloudflare R2, Wasabi, Backblaze B2) use the
`s3://` scheme with an endpoint configured per Litestream's docs.

---

## Command reference

```text
ledger/litestream-replicate.sh --describe
ledger/litestream-replicate.sh check
ledger/litestream-replicate.sh validate  --db <path> --replica <url>
ledger/litestream-replicate.sh replicate --db <path> --replica <url>   # long-running
ledger/litestream-replicate.sh restore   --db <path> --replica <url>
```

Error codes (also in `--describe`):

| Code                      | Meaning                                              |
|---------------------------|------------------------------------------------------|
| `MISSING_FLAG`            | A required `--db` / `--replica` flag was not given.  |
| `INVALID_INPUT`           | Bad value (control chars, `..` traversal, etc.).     |
| `UNSUPPORTED_SCHEME`      | Replica scheme is not one of s3/gcs/abs/sftp/file.   |
| `PARENT_DIR_MISSING`      | The db path's parent directory does not exist.       |
| `LITESTREAM_NOT_AVAILABLE`| Litestream binary not found on `PATH`.               |

All control commands (`check`, `validate`) report errors in the JSON
`error_code` field and **exit 0**.

---

## Testing

```bash
shellcheck -S warning ledger/litestream-replicate.sh ledger/eval-litestream.sh
bash -n ledger/litestream-replicate.sh
bash ledger/eval-litestream.sh   # runs with a stub litestream; no real binary needed
```
