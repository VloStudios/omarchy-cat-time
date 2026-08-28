#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import secrets
import stat
import subprocess
from pathlib import Path

STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "cat-time"
STATE_FILE = STATE_DIR / "state.json"
DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MAX_STATE_BYTES = 1024 * 1024


def defaults():
    return {
        "schedule": [{"day": d, "screen_minutes": 240, "sleep": "23:00", "wake": "07:00"} for d in DAYS],
        "usage": {}, "last_tick": None, "ignored": {}
    }


def load():
    data = defaults()
    try:
        flags = os.O_RDONLY
        if hasattr(os, "O_NONBLOCK"):
            flags |= os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(STATE_FILE, flags)
        with os.fdopen(fd, "rb") as state_file:
            file_stat = os.fstat(state_file.fileno())
            if not stat.S_ISREG(file_stat.st_mode):
                raise OSError("state file must be a regular file")
            saved_text = state_file.read(MAX_STATE_BYTES + 1)
            if len(saved_text) > MAX_STATE_BYTES:
                raise ValueError("state file too large")
        saved = json.loads(saved_text.decode("utf-8"))
        if isinstance(saved, dict):
            data.update(saved)
    except (OSError, ValueError, UnicodeDecodeError):
        pass
    if not isinstance(data.get("schedule"), list) or len(data["schedule"]) != 7:
        data["schedule"] = defaults()["schedule"]
    return data


def save(data):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    tmp = STATE_DIR / f".{STATE_FILE.name}.{secrets.token_hex(8)}.tmp"
    fd = os.open(tmp, flags, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
            tmp_file.write(json.dumps(data, indent=2) + "\n")
            tmp_file.flush()
            os.fsync(tmp_file.fileno())
        os.replace(tmp, STATE_FILE)
    except OSError:
        tmp.unlink(missing_ok=True)
        raise


def hm(value):
    h, m = map(int, value.split(":"))
    return h * 60 + m


def fmt(minutes):
    return f"{(minutes // 60) % 24:02d}:{minutes % 60:02d}"


def session_is_idle():
    """Ask logind so time behind the idle lock/screensaver is not charged."""
    try:
        result = subprocess.run(
            ["loginctl", "show-user", str(os.getuid()), "-p", "IdleHint", "--value"],
            text=True, capture_output=True, timeout=2, check=False
        )
        return result.stdout.strip().lower() == "yes"
    except (OSError, subprocess.TimeoutExpired):
        return False


def sleep_active(data, now):
    minute = now.hour * 60 + now.minute
    today = data["schedule"][now.weekday()]
    previous = data["schedule"][(now.weekday() - 1) % 7]
    # Today's bedtime applies tonight; yesterday's bedtime owns this morning.
    if minute >= hm(today["sleep"]):
        return True, today["wake"]
    if minute < hm(previous["wake"]):
        return True, previous["wake"]
    return False, today["wake"]


def status(data, tick=False):
    now = dt.datetime.now()
    key = now.date().isoformat()
    if tick:
        previous = data.get("last_tick")
        elapsed = 0
        if previous:
            try:
                elapsed = max(0, min(30, int(now.timestamp() - float(previous))))
            except (TypeError, ValueError):
                pass
        if not session_is_idle():
            data["usage"][key] = int(data["usage"].get(key, 0)) + elapsed
        data["last_tick"] = now.timestamp()
        # Keep only a modest rolling history.
        data["usage"] = {k: v for k, v in data["usage"].items() if k >= (now.date() - dt.timedelta(days=14)).isoformat()}

    row = data["schedule"][now.weekday()]
    used = int(data["usage"].get(key, 0))
    limit = int(row["screen_minutes"]) * 60
    sleeping, wake = sleep_active(data, now)
    ignored = data.get("ignored", {}).get(key, [])
    reason = ""
    if sleeping and "sleep" not in ignored:
        reason = "sleep"
    elif used >= limit and "screen" not in ignored:
        reason = "screen"
    remaining = max(0, limit - used)
    out = {
        "reason": reason,
        "used_seconds": used,
        "remaining_seconds": remaining,
        "limit_minutes": row["screen_minutes"],
        "sleep": row["sleep"], "wake": wake,
        "today": DAYS[now.weekday()], "schedule": data["schedule"]
    }
    save(data)
    return out


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("tick")
    ignore = sub.add_parser("ignore")
    ignore.add_argument("reason", choices=["screen", "sleep"])
    change = sub.add_parser("change")
    change.add_argument("day", type=int, choices=range(7))
    change.add_argument("field", choices=["screen", "sleep", "wake"])
    change.add_argument("delta", type=int)
    args = parser.parse_args()
    data = load()
    if args.command == "ignore":
        key = dt.date.today().isoformat()
        values = data.setdefault("ignored", {}).setdefault(key, [])
        if args.reason not in values:
            values.append(args.reason)
        save(data)
    elif args.command == "change":
        row = data["schedule"][args.day]
        if args.field == "screen":
            row["screen_minutes"] = max(15, min(1440, int(row["screen_minutes"]) + args.delta))
        else:
            row[args.field] = fmt((hm(row[args.field]) + args.delta) % 1440)
        save(data)
    print(json.dumps(status(data, args.command == "tick")))


if __name__ == "__main__":
    main()
