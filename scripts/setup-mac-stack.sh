#!/bin/bash
# setup-mac-stack.sh — install Mac-side daemons that mirror the Linux stack.
#
# Run this AFTER switch-to-here.command has placed the canonical files on
# this Mac. This script installs:
#
#   - whisper.cpp with Metal acceleration (Apple Silicon GPU) — the Mac
#     equivalent of the CUDA whisper daemon on Linux. For voice → text from
#     Telegram audio messages.
#
#   - cliclick — keyboard/mouse injection for macOS (the Mac equivalent of
#     ydotool on Linux). Used by the Telegram bridge to inject typed text
#     into Terminal.app where Claude Code runs.
#
#   - boto3 + zstandard + aiogram + faster-whisper Python deps for the bot.
#
#   - LaunchAgent plists so daemons auto-start on login (the macOS
#     equivalent of systemd user services).
#
# Pre-configured for keivanmalhani's M3 Pro / Tahoe 26.5 / Terminal.app.
# Idempotent — safe to re-run.

set -e
B="\033[1m"; D="\033[2m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; X="\033[0m"

echo
echo -e "${B}setup-mac-stack · install daemons that mirror the Linux setup${X}"
echo

# ---------- 1. Homebrew ----------
echo -e "${B}[1/6]${X} Homebrew"
if ! command -v brew >/dev/null; then
  echo -e "  installing Homebrew (one-time)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Tahoe-on-Apple-Silicon Homebrew lives at /opt/homebrew/bin
  [ -f /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
fi
echo -e "  ${G}✓${X} brew at $(command -v brew)"

# ---------- 2. cliclick (keyboard injection) ----------
echo
echo -e "${B}[2/6]${X} cliclick (Telegram → Terminal injection)"
if ! command -v cliclick >/dev/null; then
  brew install cliclick
fi
echo -e "  ${G}✓${X} cliclick at $(command -v cliclick)"
echo -e "  ${Y}grant Accessibility permission${X} when prompted (Settings → Privacy & Security → Accessibility)"

# ---------- 3. whisper.cpp Metal ----------
echo
echo -e "${B}[3/6]${X} whisper.cpp (Metal-accelerated voice transcription)"
if ! command -v whisper-cli >/dev/null && ! command -v whisper-cpp >/dev/null; then
  brew install whisper-cpp
fi
WHISPER_BIN=$(command -v whisper-cli || command -v whisper-cpp)
echo -e "  ${G}✓${X} whisper.cpp at $WHISPER_BIN"

# Download a model if missing
MODEL_DIR="$HOME/.local/share/whisper.cpp/models"
mkdir -p "$MODEL_DIR"
if [ ! -f "$MODEL_DIR/ggml-medium.en.bin" ]; then
  echo -e "  downloading medium.en model (~1.4 GB) — one-time..."
  curl -L -o "$MODEL_DIR/ggml-medium.en.bin" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin"
fi
echo -e "  ${G}✓${X} model at $MODEL_DIR/ggml-medium.en.bin"

# ---------- 4. Python deps ----------
echo
echo -e "${B}[4/6]${X} Python deps (boto3, zstandard, aiogram, requests)"
python3 -m pip install --user --upgrade boto3 zstandard aiogram requests 2>&1 | tail -3
echo -e "  ${G}✓${X} python deps installed"

# ---------- 5. LaunchAgent plists ----------
echo
echo -e "${B}[5/6]${X} LaunchAgent plists (auto-start daemons on login)"
PLIST_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$PLIST_DIR"

# Telegram bot daemon
cat > "$PLIST_DIR/com.keivanm.handoff-telegram.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.keivanm.handoff-telegram</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/Users/keivanmalhani/.local/share/autobot/bridges/telegram_bot_mac.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/keivanmalhani/Library/Logs/handoff-telegram.log</string>
  <key>StandardErrorPath</key><string>/Users/keivanmalhani/Library/Logs/handoff-telegram.err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
launchctl load "$PLIST_DIR/com.keivanm.handoff-telegram.plist" 2>/dev/null || true
echo -e "  ${G}✓${X} LaunchAgent: handoff-telegram"

# Auto-backup driver (Mac equivalent of the Linux systemd timer)
cat > "$PLIST_DIR/com.keivanm.handoff-autobackup.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.keivanm.handoff-autobackup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/Users/keivanmalhani/.local/share/autobot/lib/r2_sync.py</string>
    <string>push</string>
    <string>auto-mac</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardOutPath</key><string>/Users/keivanmalhani/Library/Logs/handoff-autobackup.log</string>
  <key>StandardErrorPath</key><string>/Users/keivanmalhani/Library/Logs/handoff-autobackup.err</string>
</dict>
</plist>
PLIST
launchctl load "$PLIST_DIR/com.keivanm.handoff-autobackup.plist" 2>/dev/null || true
echo -e "  ${G}✓${X} LaunchAgent: handoff-autobackup (hourly)"

# ---------- 6. test ----------
echo
echo -e "${B}[6/6]${X} smoke test"
echo -e "  testing R2 connection..."
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.expanduser("~/.local/share/autobot/lib"))
try:
    from r2_usage import s3_client, BUCKET
    s3_client().head_bucket(Bucket=BUCKET)
    print("  ✓ R2 reachable")
except Exception as e:
    print(f"  ✗ R2 unreachable: {e}")
    sys.exit(1)
PY

echo
echo -e "${G}${B}✓ Mac stack ready.${X}"
echo
echo -e "${B}what runs now on this Mac:${X}"
echo -e "  ${D}- Telegram bot (auto-start on login, restarts on crash)${X}"
echo -e "  ${D}- Hourly auto-backup to R2 (only if files changed)${X}"
echo
echo -e "${B}what to do next:${X}"
echo -e "  1. ${B}System Settings → Privacy & Security → Accessibility${X} — grant cliclick permission"
echo -e "  2. ${B}System Settings → Privacy & Security → Microphone${X} — grant Terminal/cliclick if you'll use voice"
echo -e "  3. Open Claude Code in Terminal and you're back where you left off."
echo
