#!/usr/bin/env python3
"""Mac-side Telegram bot — port of the Linux ydotool-based bot for macOS.

Replaces ydotool with cliclick + AppleScript-activate-Terminal for keystroke
injection. Replaces the CUDA whisper daemon with local whisper-cli (Metal).

Designed to be installed by setup-mac-stack.sh and started via the
LaunchAgent at ~/Library/LaunchAgents/com.keivanm.handoff-telegram.plist.

Read the four R2_* + BOT_TOKEN + ALLOWED_USER_ID values from:
  ~/Documents/autobot-vault/accounts/telegram.env
  ~/Documents/autobot-vault/accounts/cloudflare-r2.env

Pre-configured for Apple Silicon / Tahoe 26.5 / Terminal.app / keivanmalhani.

Limitations vs the Linux bot:
- No cc-loop integration (autonomous loop runner lives on Linux)
- No SQLite task queue interface
- ccusage / plan-usage commands show the LINUX dashboard's data via
  HTTP fetch over Tailscale (when reachable), or a local fallback message.

Commands handled:
  /start /help            — help text
  /status                 — local Mac stack health
  /handoff_state          — show R2 active machine + last sync
  /backup_now             — push snapshot now
  /switch_to_mac          — push state + mark Mac active (idempotent on Mac)
  /switch_to_linux        — push state + mark Linux active (run before
                            you go back to Linux)
  any other text          — inject into Terminal.app via cliclick
  voice/audio/video       — whisper-cli transcribe → inject into Terminal
  photo                   — download to ~/Pictures/telegram-incoming/
                            then inject the path
"""
from __future__ import annotations
import os, sys, time, json, asyncio, subprocess, html, socket, pathlib, datetime
from pathlib import Path
import logging

# ---------- env loading ----------
HOME = Path.home()
VAULT = HOME / "Documents/autobot-vault/accounts"

def _load_env(p: Path):
    if not p.exists(): return {}
    out = {}
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out

_tg = _load_env(VAULT / "telegram.env")
_r2 = _load_env(VAULT / "cloudflare-r2.env")
BOT_TOKEN = _tg.get("BOT_TOKEN", "")
ALLOWED = int(_tg.get("ALLOWED_USER_ID", "0") or "0")
if not BOT_TOKEN or not ALLOWED:
    sys.exit("missing BOT_TOKEN / ALLOWED_USER_ID in telegram.env")

# ---------- aiogram setup ----------
try:
    from aiogram import Bot, Dispatcher, types, F
    from aiogram.filters import Command
except ImportError:
    sys.exit("aiogram not installed. Run: pip install --user aiogram")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("bot-mac")

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()
DELIVERY_LOCK = asyncio.Lock()

PHOTOS_DIR = HOME / "Pictures/telegram-incoming"
PHOTOS_DIR.mkdir(parents=True, exist_ok=True)
MEDIA_DIR = HOME / "Music/telegram-incoming"
MEDIA_DIR.mkdir(parents=True, exist_ok=True)

INBOX = HOME / ".cache/claude-tg-inbox"
INBOX.mkdir(parents=True, exist_ok=True)

# ---------- platform helpers (cliclick + AppleScript) ----------
def _run(cmd: list[str], **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def _activate_terminal():
    """AppleScript: bring Terminal.app to front so cliclick types into it."""
    script = 'tell application "Terminal" to activate'
    _run(["osascript", "-e", script], timeout=3)
    time.sleep(0.15)  # let focus settle

def _cliclick_type(text: str):
    """Use cliclick to type text into the focused window.
    cliclick 't:' takes a string but escapes are limited — do it in chunks."""
    # cliclick has limits on single-call length; chunk every 200 chars
    for i in range(0, len(text), 200):
        chunk = text[i:i+200]
        # cliclick t: doesn't handle newlines well; replace them with literal \n
        # which we then split with cliclick kp:return separately
        _run(["cliclick", "-w", "8", f"t:{chunk}"], timeout=15)

def _cliclick_clear_line():
    """Send Esc + Ctrl-U to clear current readline input on macOS Terminal."""
    _run(["cliclick", "kp:escape"], timeout=2)
    # cliclick keystroke-with-modifier syntax: kd:ctrl, kp:u, ku:ctrl
    _run(["cliclick", "kd:ctrl", "t:u", "ku:ctrl"], timeout=2)

def _cliclick_press_enter():
    _run(["cliclick", "kp:return"], timeout=2)

# ---------- whisper (local Metal-accelerated) ----------
WHISPER_BIN = None
for cand in ["whisper-cli", "whisper-cpp", "/opt/homebrew/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp"]:
    if subprocess.run(["which", cand], capture_output=True).returncode == 0 or pathlib.Path(cand).is_file():
        WHISPER_BIN = cand
        break
WHISPER_MODEL = HOME / ".local/share/whisper.cpp/models/ggml-medium.en.bin"

def transcribe(path: Path) -> str:
    if not WHISPER_BIN or not WHISPER_MODEL.exists():
        return f"(whisper not installed — model expected at {WHISPER_MODEL})"
    # Convert to 16kHz mono wav (whisper.cpp requirement)
    wav = Path(f"/tmp/{path.stem}.wav")
    _run(["ffmpeg", "-y", "-i", str(path), "-ar", "16000", "-ac", "1", "-f", "wav", str(wav)],
         timeout=30)
    if not wav.exists():
        return "(audio conversion failed)"
    r = _run([WHISPER_BIN, "-m", str(WHISPER_MODEL), "-f", str(wav), "--output-txt"],
             timeout=180)
    txt_file = wav.with_suffix(".wav.txt")
    if txt_file.exists():
        text = txt_file.read_text().strip()
        wav.unlink(missing_ok=True); txt_file.unlink(missing_ok=True)
        return text or "(transcription empty — file may have no speech)"
    return f"(whisper failed: {r.stderr[:200]})"

# ---------- delivery (the platform difference) ----------
async def deliver_to_terminal(text: str):
    """Inject text into Terminal.app on macOS via cliclick + AppleScript activate."""
    cleaned = "".join(c for c in text if c == "\n" or c == "\t" or (ord(c) >= 32 and ord(c) != 127))
    log.info(f"deliver: acquiring lock for {len(cleaned)} chars")
    try:
        await asyncio.wait_for(DELIVERY_LOCK.acquire(), timeout=120)
    except asyncio.TimeoutError:
        log.warning("DELIVERY_LOCK held >120s — falling back to inbox")
        ts = int(time.time() * 1000)
        (INBOX / f"{ts}-mac.txt").write_text(cleaned)
        return
    try:
        # Live log
        try:
            (HOME / ".cache/claude-tg-live.log").open("a").write(
                f"[{time.strftime('%H:%M:%S')}] {cleaned}\n"
            )
        except Exception: pass

        # macOS notification (display notification AppleScript)
        try:
            _run(["osascript", "-e",
                  f'display notification "{cleaned[:120]}" with title "phone → Terminal"'],
                 timeout=2)
        except Exception: pass

        # Activate Terminal, clear current line, type message, press Enter
        _activate_terminal()
        _cliclick_clear_line()
        _cliclick_type(cleaned)
        _cliclick_press_enter()
        log.info(f"deliver: injected {len(cleaned)} chars + Enter")
    except Exception as e:
        log.error(f"deliver failed: {e}; writing inbox fallback")
        ts = int(time.time() * 1000)
        (INBOX / f"{ts}-mac-fallback.txt").write_text(cleaned)
    finally:
        DELIVERY_LOCK.release()

# ---------- handlers ----------
HELP = (
    "autobot · Mac\n"
    "Pin this so commands stay handy.\n\n"
    "any text         → typed into Terminal.app (Claude Code session)\n"
    "voice/audio      → whisper transcribe → typed into Terminal\n"
    "photo            → saved to ~/Pictures/telegram-incoming\n\n"
    "/status          local Mac health\n"
    "/handoff_state   active machine + last R2 sync\n"
    "/backup_now      push snapshot to R2\n"
    "/switch_to_linux push + mark Linux active (do before reboot)\n"
    "/switch_to_mac   re-mark this Mac active\n"
    "/help            this list"
)

@dp.message(Command("start"))
@dp.message(Command("help"))
async def help_cmd(m: types.Message):
    if m.from_user.id != ALLOWED: return
    await m.reply(f"<pre>{html.escape(HELP)}</pre>", parse_mode="HTML")

@dp.message(Command("status"))
async def status_cmd(m: types.Message):
    if m.from_user.id != ALLOWED: return
    host = socket.gethostname()
    # local checks: cliclick installed? whisper bin? bot uptime?
    parts = [f"host: {host}",
             f"cliclick: {'✓' if subprocess.run(['which','cliclick'],capture_output=True).returncode==0 else '✗'}",
             f"whisper: {'✓ ' + str(WHISPER_BIN) if WHISPER_BIN else '✗ not installed'}",
             f"r2 creds: {'✓' if _r2 else '✗'}"]
    await m.reply("Mac stack:\n" + "\n".join(parts))

# r2_sync sits at ~/.local/share/autobot/lib/r2_sync.py after switch-to-here
sys.path.insert(0, str(HOME / ".local/share/autobot/lib"))
def _r2_call(fn_name: str, **kw):
    try:
        import r2_sync
        return getattr(r2_sync, fn_name)(**kw)
    except Exception as e:
        return {"_error": f"{type(e).__name__}: {e}"}

@dp.message(Command("handoff_state"))
async def handoff(m: types.Message):
    if m.from_user.id != ALLOWED: return
    state = await asyncio.to_thread(_r2_call, "get_handoff_state")
    if "_error" in state:
        await m.reply(f"err: {state['_error']}"); return
    txt = (f"active machine: {state.get('active_machine') or '(never set)'}\n"
           f"last push: {state.get('last_push_host') or '-'} at {state.get('last_push_at') or '-'}")
    await m.reply(txt)

@dp.message(Command("backup_now"))
async def backup(m: types.Message):
    if m.from_user.id != ALLOWED: return
    await m.reply("snapshotting Mac state to R2...")
    snap = await asyncio.to_thread(_r2_call, "push_snapshot", label="manual-mac")
    if "_error" in snap:
        await m.reply(f"err: {snap['_error']}"); return
    md = snap.get("metadata", {})
    await m.reply(f"snapshot pushed · {md.get('files', '?')} files · "
                  f"{md.get('archive_bytes', 0)/1024/1024:.1f}MB compressed\n"
                  f"key: {snap.get('key', '?')}")

async def _do_switch(target: str, m: types.Message):
    snap = await asyncio.to_thread(_r2_call, "push_snapshot", label=f"switch-to-{target}-from-mac")
    if "_error" in snap:
        await m.reply(f"snapshot failed: {snap['_error']}"); return
    state = await asyncio.to_thread(_r2_call, "set_handoff_state", active_machine=target, label=f"switch_to_{target}")
    md = snap.get("metadata", {})
    await m.reply(f"switch → {target}\n"
                  f"snapshot: {md.get('files', '?')} files · {md.get('archive_bytes', 0)/1024/1024:.1f}MB\n"
                  f"active: {state.get('active_machine')}")

@dp.message(Command("switch_to_linux"))
async def sw_linux(m: types.Message):
    if m.from_user.id != ALLOWED: return
    await m.reply("pushing Mac state to R2 + marking Linux as active...")
    await _do_switch("linux", m)

@dp.message(Command("switch_to_mac"))
async def sw_mac(m: types.Message):
    if m.from_user.id != ALLOWED: return
    await m.reply("re-marking Mac as active...")
    await _do_switch("mac", m)

# Voice / audio / video
@dp.message(F.voice | F.audio | F.video | F.video_note)
async def media(m: types.Message):
    if m.from_user.id != ALLOWED: return
    if m.voice:    fid, ext, kind = m.voice.file_id, ".ogg", "voice"
    elif m.audio:  fid, ext, kind = m.audio.file_id, "." + (m.audio.mime_type or "audio/mpeg").split("/")[-1].split(";")[0], "audio"
    elif m.video:  fid, ext, kind = m.video.file_id, ".mp4", "video"
    else:          fid, ext, kind = m.video_note.file_id, ".mp4", "video-note"
    fobj = await bot.get_file(fid)
    ts = int(time.time())
    local = MEDIA_DIR / f"phone-{kind}-{ts}-{fid[:12]}{ext}"
    await bot.download_file(fobj.file_path, str(local))
    await m.reply(f"transcribing {kind}...")
    text = await asyncio.to_thread(transcribe, local)
    cap = (m.caption or "").strip()
    prompt = f"[{kind} from phone, transcribed] {text}"
    if cap: prompt += f" — caption: {cap}"
    if m.video or m.video_note: prompt += f" — file at {local}"
    await deliver_to_terminal(prompt)

# Photos
@dp.message(F.photo | (F.document & F.document.mime_type.startswith("image/")))
async def photo(m: types.Message):
    if m.from_user.id != ALLOWED: return
    fid = (m.photo[-1].file_id if m.photo else m.document.file_id)
    fobj = await bot.get_file(fid)
    local = PHOTOS_DIR / f"phone-{int(time.time())}-{fid[:12]}.jpg"
    await bot.download_file(fobj.file_path, str(local))
    cap = (m.caption or "").strip()
    prompt = f"[photo from phone] {local}"
    if cap: prompt += f"  caption: {cap}"
    await deliver_to_terminal(prompt)

# Plain text fallback (everything not a command)
@dp.message(F.text & ~F.text.startswith("/"))
async def plain(m: types.Message):
    if m.from_user.id != ALLOWED: return
    await deliver_to_terminal(m.text)


async def main():
    log.info(f"starting bot for ALLOWED={ALLOWED}, host={socket.gethostname()}")
    log.info(f"whisper bin: {WHISPER_BIN}")
    log.info(f"R2 endpoint: {_r2.get('R2_ENDPOINT', '(not configured)')}")
    await dp.start_polling(bot, handle_signals=True)


if __name__ == "__main__":
    asyncio.run(main())
