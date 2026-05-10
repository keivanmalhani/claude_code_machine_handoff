# claude-code-machine-handoff

Linux ↔ Mac handoff for a Claude Code session, via Cloudflare R2 as the cloud-canonical store.

## What this is

A small set of scripts for moving a working Claude Code session between two machines without losing state. Built specifically for the keivanmalhani setup:

- **Linux (canonical)**: a Bazzite box at home with the full stack — Telegram bot, whisper-CUDA daemon, dashboard, autobot-audit timer.
- **MacBook (mobile)**: M3 Pro running macOS Tahoe 26.5, used while traveling or while the Linux box is rebooted into Windows for gaming.
- **Cloud handoff baton**: a private Cloudflare R2 bucket (`claude-code-handoff`) holding zstd-compressed snapshots of code dirs + a JSON state file.

## How a switch works

### Linux → Mac

1. On Linux, send `/switch_to_mac` to the Telegram bot, OR click the **switch to mac** button on the dashboard at `127.0.0.1:8765`.
2. The Linux box snapshots `~/dev/malbqz`, `~/.local/share/autobot/`, `~/.claude/memory/`, `~/.claude/hooks/`, `~/notes/`, compresses to zstd (typically 5-10× ratio), and uploads to R2.
3. State JSON `switch/state.json` is updated to mark Mac as the active machine.
4. The Linux Telegram bot replies with the snapshot key + size.

### On the Mac

1. Open Terminal.app.
2. Drag `scripts/switch-to-here.command` from this repo's clone onto the terminal, or `cd` to it and run.
3. First-run only: prompt for R2 credentials (paste the four `R2_*` lines from your Linux vault).
4. Script downloads the latest snapshot, previews what it would extract, asks for confirm.
5. Extracts to `$HOME` on Mac.
6. Marks Mac as the active machine in R2 state JSON.

### Mac → Linux

1. On Mac, send `/switch_to_linux` to Telegram.
2. Same snapshot+upload+state-update on the Mac side.
3. Reboot Linux back into Bazzite.
4. Linux's auto-backup timer (every 60 min, only if change detected) will pull the Mac snapshot on its next tick. Or run `/backup_now` from Telegram to force immediately.

## Files

```
scripts/
  switch-to-here.command   Mac bootstrap (double-clickable, chmod +x)
  setup-mac-stack.sh       Mac-side dependency install (whisper.cpp + cliclick + Telegram bot)

lib/
  (symlinked from /home/keivanm/.local/share/autobot/lib/ on Linux —
   r2_sync.py, r2_usage.py)

docs/
  audit-checklist.md       Cloudflare audit + billing-safety checklist
```

## Cost / billing safety

Cloudflare R2 free tier:

- 10 GB storage
- 1 million Class A (write/list) operations per month
- 10 million Class B (read/head) operations per month
- **Zero egress fees forever**

A typical snapshot is ~20-50 MB compressed. Even pushing one per hour puts us at ~50 ops/day, well inside free-tier limits.

A $1 billing alert is configured at the Cloudflare account level — if anything ever generates a charge, an email goes out immediately.

The autobot dashboard has a live "cloudflare R2 · billing safety" panel showing storage used, ops count this month, projected overage. Source-of-truth: local op counter + S3 list (no other process writes to this bucket from outside this setup).

## Threat model

- **R2 credentials in plaintext** at `~/Documents/autobot-vault/accounts/cloudflare-r2.env` (chmod 600). If that file leaks, an attacker has Object Read + Write on the bucket. Plan: re-create as User API Token scoped to single bucket before any production-critical use.
- **Snapshot tarballs unencrypted at rest** in R2. R2 itself encrypts at rest with their managed keys. If you want client-side encryption, layer `age` on top — we may add this later.
- **Bucket is private** (no public r2.dev subdomain, no custom domain, no CORS).

## Restoring an older snapshot

```bash
python3 ~/.local/share/autobot/lib/r2_sync.py list      # show recent snapshots
python3 ~/.local/share/autobot/lib/r2_sync.py pull      # download latest to /tmp
# Or pull a specific snapshot by key:
python3 -c "import sys; sys.path.insert(0, '~/.local/share/autobot/lib'); \
            import r2_sync; print(r2_sync.pull_snapshot('snapshots/2026-05-10T012345-host-label.tar.zst'))"
```
