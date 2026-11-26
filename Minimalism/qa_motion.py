"""Observe native playtest motion and the Windows foreground from read-only logs."""

import argparse
from collections import Counter, defaultdict
import ctypes
from ctypes import wintypes
import json
import math
from pathlib import Path
from statistics import median
import time


class Foreground:
    def __init__(self, run):
        self.run = run
        self.user = ctypes.WinDLL("user32", use_last_error=True)
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.user.GetForegroundWindow.restype = wintypes.HWND
        self.user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        self.user.GetWindowThreadProcessId.restype = wintypes.DWORD
        self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.QueryFullProcessImageNameW.argtypes = [
            wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD),
        ]
        self.kernel.QueryFullProcessImageNameW.restype = wintypes.BOOL
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.CloseHandle.restype = wintypes.BOOL

    def get(self):
        window = self.user.GetForegroundWindow()
        pid = wintypes.DWORD()
        if not window or not self.user.GetWindowThreadProcessId(window, ctypes.byref(pid)):
            return None, None, None
        handle = self.kernel.OpenProcess(0x1000, False, pid.value)
        if not handle:
            return pid.value, None, None
        try:
            name = ctypes.create_unicode_buffer(32768)
            size = wintypes.DWORD(len(name))
            if not self.kernel.QueryFullProcessImageNameW(handle, 0, name, ctypes.byref(size)):
                return pid.value, None, None
            path = Path(name.value)
            slot = None
            if path.is_relative_to(self.run):
                slot = path.relative_to(self.run).parts[0]
            return pid.value, path.name, slot
        finally:
            self.kernel.CloseHandle(handle)


class RunLog:
    def __init__(self):
        self.offset = 0
        self.trailing = b""
        self.checkpoint = None
        self.input = None
        self.planning = []
        self.playing = []
        self.focus_samples = Counter()
        self.unfocused_steps = 0
        self.cleared = []
        self.timeouts = 0

    def read(self, path):
        try:
            with path.open("rb") as stream:
                stream.seek(self.offset)
                data = self.trailing + stream.read()
                self.offset = stream.tell()
        except FileNotFoundError:
            return
        lines = data.split(b"\n")
        self.trailing = lines.pop()
        for line in lines:
            if not line.strip():
                continue
            entry = json.loads(line)
            event = entry["event"]
            if event == "clear":
                self.cleared.append(entry["level"])
            elif event == "planning_timeout":
                self.timeouts += 1
            elif event == "input":
                self.input = entry
                if self.checkpoint is not None:
                    self.planning.append(entry["elapsed"] - self.checkpoint["elapsed"])
            elif event == "checkpoint":
                if self.input is not None:
                    previous = self.checkpoint
                    if previous and entry["level"] == previous["level"] and entry["tick"] > previous["tick"]:
                        steps = entry["tick"] - previous["tick"]
                        self.playing.append((steps, entry["seconds_after_command"]))
                        if entry.get("focused") is False and previous.get("focused") is False:
                            self.unfocused_steps += steps
                    self.input = None
                self.checkpoint = entry
                self.focus_samples[entry.get("focused")] += 1
                yield entry


def stats(values):
    if not values:
        return None
    sorted_values = sorted(values)
    return {
        "count": len(values),
        "median_s": round(median(values), 3),
        "p95_s": round(sorted_values[math.ceil(0.95 * len(values)) - 1], 3),
        "max_s": round(max(values), 3),
    }


def report(foreground, slots, background):
    for slot, log in sorted(slots.items()):
        rates = [frames / seconds for frames, seconds in log.playing if seconds > 0]
        planned_seconds = sum(log.planning)
        motion_seconds = sum(seconds for _, seconds in log.playing)
        print(json.dumps({
            "slot": slot,
            "native_steps": sum(frames for frames, _ in log.playing),
            "median_moving_steps_per_second": round(median(rates), 1) if rates else None,
            "checkpoint_to_command": stats(log.planning),
            "planning_share": round(planned_seconds / (planned_seconds + motion_seconds), 3)
            if planned_seconds + motion_seconds > 0 else None,
            "timeouts": log.timeouts,
            "native_unfocused_checkpoints": log.focus_samples[False],
            "native_unfocused_steps_between_checkpoints": log.unfocused_steps,
            "advancing_steps_while_other_foreground_sampled": background[slot],
            "cleared": log.cleared,
        }))
    print(json.dumps({"foreground_samples": dict(foreground)}))


def observe(run, seconds, interval, events):
    foreground = Foreground(run)
    sampled_foreground = Counter()
    background = Counter()
    slots = defaultdict(RunLog)
    previous_owner = None
    start = time.monotonic()
    while True:
        pid, process, owner = foreground.get()
        sampled_foreground[owner or process or "<unknown>"] += 1
        if events and (pid, owner) != previous_owner:
            print(json.dumps({"event": "foreground", "sample_time": time.time(),
                              "pid": pid, "process": process, "slot": owner}), flush=True)
        for path in sorted(run.glob("slot-*/minimalism-*/run.jsonl")):
            slot = path.parent.parent.name
            log = slots[slot]
            before = log.checkpoint
            for checkpoint in log.read(path):
                if events and before is not None:
                    print(json.dumps({
                        "event": "checkpoint", "sample_time": time.time(), "run_time": checkpoint.get("time"),
                        "slot": slot, "sequence": checkpoint["sequence"], "level": checkpoint["level"],
                        "tick": checkpoint["tick"], "engine_focused": checkpoint.get("focused"),
                    }), flush=True)
            after = log.checkpoint
            if (pid is not None and process and owner != slot and previous_owner == (pid, owner)
                    and before and after and before["level"] == after["level"] and after["tick"] > before["tick"]):
                background[slot] += after["tick"] - before["tick"]
        previous_owner = pid, owner
        remaining = seconds - (time.monotonic() - start)
        if remaining <= 0:
            break
        time.sleep(min(interval, remaining))
    report(sampled_foreground, slots, background)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=lambda name: Path(name).resolve(), help="Parallel playtest run directory")
    parser.add_argument("--seconds", type=float, default=15)
    parser.add_argument("--interval", type=float, default=0.1)
    parser.add_argument("--events", action="store_true", help="Emit timestamped foreground and checkpoint changes")
    args = parser.parse_args()
    if not args.run.is_dir() or args.seconds < 0 or args.interval <= 0:
        parser.error("Provide an existing run directory, nonnegative seconds, and a positive interval.")
    observe(args.run, args.seconds, args.interval, args.events)


if __name__ == "__main__":
    main()
