#!/bin/bash
# switch-to-here.command — double-click this on macOS to "land" the Linux session here.
#
# Pre-configured for keivanmalhani's M3 Pro / Tahoe 26.5 / Terminal.app.
# Drop this file in ~/Desktop or wherever, chmod +x once, double-click forever.
#
# What it does:
#   1. Verify Mac has the right tools (Python 3, curl) and prompt to install
#      missing ones via Homebrew.
#   2. On first run, prompt for Cloudflare R2 credentials and save them
#      securely to ~/Documents/autobot-vault/accounts/cloudflare-r2.env.
#      On subsequent runs, just reads the saved credentials.
#   3. Download the latest R2 snapshot.
#   4. Show a diff of what would be extracted (dry-run preview).
#   5. Ask for confirmation, then extract to $HOME, mark this Mac as the
#      "active machine" in the R2 handoff state.
#   6. Print a summary + instructions for any Mac-side setup steps.
#
# This is the Mac counterpart to /switch-to-mac on Linux.

set -e
set -o pipefail

cd "$(dirname "$0")"

# ANSI colors for readability in Terminal.app
B="\033[1m"; D="\033[2m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; X="\033[0m"

echo
echo -e "${B}switch-to-here · land the handoff session on this Mac${X}"
echo -e "${D}$(date '+%a %b %-d, %-I:%M %p %Z')${X}"
echo

# ---------- 1. environment check ----------
echo -e "${B}[1/5]${X} environment check"
need=()
command -v python3 >/dev/null || need+=("python3")
command -v curl    >/dev/null || need+=("curl")
command -v tar     >/dev/null || need+=("tar")
command -v zstd    >/dev/null || need+=("zstd")
if [ "${#need[@]}" -gt 0 ]; then
  echo -e "  ${Y}missing tools:${X} ${need[*]}"
  if command -v brew >/dev/null; then
    echo -e "  installing via Homebrew..."
    brew install "${need[@]}"
  else
    echo -e "  ${R}Homebrew not found.${X} Install from https://brew.sh first, then re-run."
    echo -e "  Quick install: ${B}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${X}"
    exit 1
  fi
else
  echo -e "  ${G}✓${X} python3, curl, tar, zstd all present"
fi

# ensure boto3 + zstandard + cryptography for snapshot work
# macOS system python3 (Apple/Xcode) is PEP 668 externally-managed, so
# we pass --break-system-packages — install still goes to ~/Library/Python,
# never touching the system tree. Standard pattern for user-scoped scripts
# on macOS Sonoma+ / Tahoe.
if ! python3 -c "import boto3, zstandard, cryptography" 2>/dev/null; then
  echo -e "  installing python deps (boto3 + zstandard + cryptography)..."
  python3 -m pip install --user --break-system-packages \
    boto3 zstandard cryptography 2>&1 | tail -5
fi
echo -e "  ${G}✓${X} python deps ready"

# ---------- 2. credentials ----------
echo
echo -e "${B}[2/5]${X} credentials"
VAULT_DIR="$HOME/Documents/autobot-vault/accounts"
CRED_FILE="$VAULT_DIR/cloudflare-r2.env"
mkdir -p "$VAULT_DIR"
chmod 700 "$VAULT_DIR"

if [ ! -f "$CRED_FILE" ]; then
  echo -e "  ${Y}first-run setup${X} — paste your Cloudflare R2 credentials below."
  echo -e "  Linux machine has them at: ~/Documents/autobot-vault/accounts/cloudflare-r2.env"
  echo -e "  Open that file, copy the four R2_* lines, paste here, then Ctrl-D."
  echo
  cat > "$CRED_FILE.tmp"
  if grep -q "^R2_ACCOUNT_ID=" "$CRED_FILE.tmp" \
     && grep -q "^R2_ACCESS_KEY_ID=" "$CRED_FILE.tmp" \
     && grep -q "^R2_SECRET_ACCESS_KEY=" "$CRED_FILE.tmp" \
     && grep -q "^R2_ENDPOINT=" "$CRED_FILE.tmp"; then
    mv "$CRED_FILE.tmp" "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    echo -e "  ${G}✓${X} R2 creds saved to $CRED_FILE (chmod 600)"
  else
    echo -e "  ${R}✗${X} pasted text missing required keys (R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT)"
    rm -f "$CRED_FILE.tmp"
    exit 1
  fi
else
  echo -e "  ${G}✓${X} R2 credentials already present at $CRED_FILE"
fi

# Snapshot encryption key (AES-256-GCM). Snapshots are encrypted client-side
# before pushing to R2; without this key, Mac can't decrypt what Linux pushed.
KEY_FILE="$VAULT_DIR/snapshot-encryption.key"
if [ ! -f "$KEY_FILE" ]; then
  echo
  echo -e "  ${Y}snapshot encryption key needed${X} — paste it next (single 64-hex-char line)."
  echo -e "  Linux has it at: ~/Documents/autobot-vault/accounts/snapshot-encryption.key"
  echo -e "  ${D}cat that file → copy → paste here → Ctrl-D${X}"
  echo
  cat > "$KEY_FILE.tmp"
  # Strip trailing newline, validate it's 64 hex chars
  tr -d '\n' < "$KEY_FILE.tmp" > "$KEY_FILE.trimmed"
  if [ "$(wc -c < "$KEY_FILE.trimmed")" -eq 64 ] && grep -qE '^[0-9a-fA-F]{64}$' "$KEY_FILE.trimmed"; then
    mv "$KEY_FILE.trimmed" "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    rm -f "$KEY_FILE.tmp"
    echo -e "  ${G}✓${X} encryption key saved to $KEY_FILE (chmod 600)"
  else
    echo -e "  ${R}✗${X} encryption key must be exactly 64 hex characters"
    rm -f "$KEY_FILE.tmp" "$KEY_FILE.trimmed"
    exit 1
  fi
else
  echo -e "  ${G}✓${X} encryption key already present"
fi
# Install cryptography for AES-GCM
python3 -c "from cryptography.hazmat.primitives.ciphers.aead import AESGCM" 2>/dev/null \
  || python3 -m pip install --user --break-system-packages cryptography 2>&1 | tail -3

# ---------- 3. download latest snapshot ----------
echo
echo -e "${B}[3/5]${X} pulling latest snapshot from R2"
# shellcheck disable=SC1090
set -a; . "$CRED_FILE"; set +a

PULL_DIR="$HOME/.cache/handoff-pull"
mkdir -p "$PULL_DIR"

LATEST_INFO=$(python3 - <<PY
import boto3, json, os
from botocore.config import Config
s3 = boto3.client('s3',
    endpoint_url=os.environ['R2_ENDPOINT'],
    aws_access_key_id=os.environ['R2_ACCESS_KEY_ID'],
    aws_secret_access_key=os.environ['R2_SECRET_ACCESS_KEY'],
    region_name='auto', config=Config(signature_version='s3v4'))
r = s3.get_object(Bucket=os.environ['R2_BUCKET'], Key='snapshots/latest.json')
print(r['Body'].read().decode())
PY
)

LATEST_KEY=$(echo "$LATEST_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")
LATEST_HOST=$(echo "$LATEST_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['host'])")
LATEST_FILES=$(echo "$LATEST_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['files'])")
LATEST_BYTES=$(echo "$LATEST_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['archive_bytes'])")
LATEST_TS=$(echo "$LATEST_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['created_at'])")

LATEST_NAME="$(basename "$LATEST_KEY")"
LOCAL_TARBALL="$PULL_DIR/$LATEST_NAME"
echo -e "  latest: ${B}$LATEST_NAME${X}"
echo -e "  from:    $LATEST_HOST  ·  $LATEST_TS"
echo -e "  size:    $(printf "%'d" "$LATEST_BYTES") bytes"
echo -e "  files:   $LATEST_FILES"

python3 - <<PY
import boto3, os
from botocore.config import Config
s3 = boto3.client('s3',
    endpoint_url=os.environ['R2_ENDPOINT'],
    aws_access_key_id=os.environ['R2_ACCESS_KEY_ID'],
    aws_secret_access_key=os.environ['R2_SECRET_ACCESS_KEY'],
    region_name='auto', config=Config(signature_version='s3v4'))
s3.download_file(os.environ['R2_BUCKET'], "$LATEST_KEY", "$LOCAL_TARBALL")
print("  ✓ downloaded")
PY

# Decrypt now (if .aes) so both preview and extract operate on the plain .tar.zst.
DECRYPTED_TARBALL="$LOCAL_TARBALL"
if [[ "$LATEST_KEY" == *.aes ]]; then
  echo -e "  decrypting (AES-256-GCM) using key from $KEY_FILE..."
  DECRYPTED_TARBALL="${LOCAL_TARBALL%.aes}"
  python3 - <<PY
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
key = bytes.fromhex(open("$KEY_FILE").read().strip())
blob = open("$LOCAL_TARBALL", "rb").read()
nonce, ct = blob[:12], blob[12:]
plaintext = AESGCM(key).decrypt(nonce, ct, None)
open("$DECRYPTED_TARBALL", "wb").write(plaintext)
print("  ✓ decrypted")
PY
fi

# ---------- 4. preview + confirm ----------
echo
echo -e "${B}[4/5]${X} preview — what would be extracted to ${B}\$HOME${X}"
EXTRACT_LIST="$PULL_DIR/$LATEST_NAME.list"
python3 - <<PY > "$EXTRACT_LIST"
import tarfile, zstandard
with open("$DECRYPTED_TARBALL", "rb") as f:
    dctx = zstandard.ZstdDecompressor()
    with dctx.stream_reader(f) as reader:
        with tarfile.open(fileobj=reader, mode="r|") as tar:
            for m in tar:
                print(m.name)
PY
echo -e "  ${B}top-level paths in archive (sample):${X}"
awk -F/ '{print $1"/"$2}' "$EXTRACT_LIST" | sort -u | head -10 | sed 's/^/    /'
TOTAL_FILES=$(wc -l < "$EXTRACT_LIST" | tr -d ' ')
echo -e "  total files: $TOTAL_FILES"
echo
echo -e "  ${B}what gets touched (only these paths inside \$HOME):${X}"
echo -e "    dev/malbqz/                   site code"
echo -e "    .local/share/autobot/         bot, dashboard, sync engine"
echo -e "    .claude/memory/ + .claude/hooks/   persistent memory + hooks"
echo -e "    notes/                        todo + brainstorm docs"
echo -e "    Desktop/3d printing/          3D printing files (synced both ways)"
echo
echo -e "  ${G}what is EXPLICITLY preserved (NOT touched):${X}"
echo -e "    Documents/                    Bambu Studio configs, Lightroom, etc"
echo -e "    Pictures/, Movies/            your normal Mac files"
echo -e "    Library/Application Support/  Claude Desktop, Bambu Studio app data"
echo -e "    rest of Desktop/              anything outside Desktop/3d printing"
echo -e "    everything else under \$HOME"
echo
echo -e "  ${Y}⚠ files in the 5 touched paths above WILL be overwritten by the R2 snapshot.${X}"
echo -e "  ${Y}  Bambu Studio app data + everything else stays untouched.${X}"
read -r -p "  Proceed with extract? [y/N] " ans
if [[ ! "$ans" =~ ^[Yy]$ ]]; then
  echo -e "  ${R}aborted by user.${X} The downloaded tarball is at:"
  echo -e "    $LOCAL_TARBALL"
  echo -e "  You can manually inspect it or run this script again to retry."
  exit 0
fi

# ---------- 5. extract + mark active ----------
echo
echo -e "${B}[5/5]${X} extracting + marking Mac as active machine"
zstd -d "$DECRYPTED_TARBALL" -o "$DECRYPTED_TARBALL.tar" --force >/dev/null 2>&1
tar -xf "$DECRYPTED_TARBALL.tar" -C "$HOME"
rm -f "$DECRYPTED_TARBALL.tar"
[ "$DECRYPTED_TARBALL" != "$LOCAL_TARBALL" ] && rm -f "$DECRYPTED_TARBALL"
echo -e "  ${G}✓${X} extracted to \$HOME"

python3 - <<PY
import boto3, json, os, socket
from datetime import datetime, timezone
from botocore.config import Config
s3 = boto3.client('s3',
    endpoint_url=os.environ['R2_ENDPOINT'],
    aws_access_key_id=os.environ['R2_ACCESS_KEY_ID'],
    aws_secret_access_key=os.environ['R2_SECRET_ACCESS_KEY'],
    region_name='auto', config=Config(signature_version='s3v4'))
try:
    r = s3.get_object(Bucket=os.environ['R2_BUCKET'], Key='switch/state.json')
    state = json.loads(r['Body'].read())
except Exception:
    state = {"active_machine": None, "history": []}
state["active_machine"] = "mac"
state["last_push_host"] = socket.gethostname()
state["last_push_at"] = datetime.now(timezone.utc).isoformat()
state.setdefault("history", []).append({
    "ts": state["last_push_at"], "from": state["last_push_host"],
    "to": "mac", "label": "switch_to_here_mac",
})
state["history"] = state["history"][-50:]
s3.put_object(
    Bucket=os.environ['R2_BUCKET'], Key='switch/state.json',
    Body=json.dumps(state, indent=2).encode(),
    ContentType='application/json',
)
print("  ✓ R2 state.json updated; Mac is now active")
PY

echo
echo -e "${G}${B}✓ landed.${X} You're now running on Mac with the latest Linux state."
echo
echo -e "${B}what to do next:${X}"
echo -e "  ${D}1. Open Claude Code (or whatever's natural to you on Mac).${X}"
echo -e "  ${D}2. When you're done on Mac and want to switch back, run /switch_to_linux from Telegram, then reboot Linux box.${X}"
echo -e "  ${D}3. The Linux box's auto-backup timer will pull this Mac state on its next 60-min tick (or you can trigger /backup_now from Telegram on Mac after running this).${X}"
echo
