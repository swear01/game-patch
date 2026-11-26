"""Persist soft search preferences for empirical stalls in one game room."""

from collections import Counter
import json
import math
from pathlib import Path
from uuid import uuid4


REGION_SIZE = 32
PENALTY_PER_STALL = 16
MAX_PENALTY = 128
RECORD_VERSION = 1


def _signed_band(value, scale):
    band = math.ceil(abs(value) / scale)
    return -band if value < 0 else band


def _goal_identity(goal):
    if goal is None or isinstance(goal, (int, str)):
        return goal
    return (int(goal.left), int(goal.top), int(goal.right), int(goal.bottom))


def context_key(state, goal, *, remaining, phase=0):
    """Describe a stall region for priority adjustment only."""
    return (
        (math.floor(state.x / REGION_SIZE), math.floor(state.y / REGION_SIZE)),
        (_signed_band(state.hspd, 2), _signed_band(state.vspd, 4)),
        (int(state.grounded), int(state.state), int(state.jumps), int(state.jump_held)),
        (int(state.wall_jumps), int(state.meet), int(state.wall_jump_can)),
        (int(state.invert_gravity), math.ceil(max(0, state.gravity_remaining) / 12)),
        int(remaining),
        _goal_identity(goal),
        int(phase or 0),
    )


def serialize_record(key):
    return json.dumps({"kind": "search_stall", "version": RECORD_VERSION, "context": key})


def _freeze(value):
    if isinstance(value, list):
        return tuple(_freeze(item) for item in value)
    if value is None or isinstance(value, (int, str)):
        return value
    raise ValueError("Invalid search context")


def deserialize_record(line):
    """Return a context only for this format, leaving old death reports intact."""
    try:
        record = json.loads(line)
        if (not isinstance(record, dict) or record.get("kind") != "search_stall"
                or record.get("version") != RECORD_VERSION):
            return None
        context = _freeze(record.get("context"))
    except (TypeError, ValueError):
        return None
    return context if isinstance(context, tuple) and len(context) == 8 else None


class SearchMemory:
    def __init__(self, room_directory=None):
        self.directory = Path(room_directory) / "search" if room_directory is not None else None
        self.counts = Counter()
        self.seen = set()

    def penalty(self, key):
        return min(MAX_PENALTY, self.counts[key] * PENALTY_PER_STALL)

    def load(self):
        """Read new observations without counting a shared record twice."""
        if self.directory is None:
            return 0
        loaded = 0
        try:
            paths = list(self.directory.glob("*.json"))
        except OSError:
            return 0
        for path in paths:
            if path.name in self.seen:
                continue
            try:
                key = deserialize_record(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError):
                continue
            self.seen.add(path.name)
            if key is not None:
                self.counts[key] += 1
                loaded += 1
        return loaded

    def record(self, key):
        """Record locally and, when configured, publish one atomic observation."""
        self.counts[key] += 1
        if self.directory is None:
            return None
        destination = self.directory / f"{uuid4().hex}.json"
        staging = destination.with_suffix(".tmp")
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            staging.write_text(serialize_record(key), encoding="utf-8")
            staging.replace(destination)
        except OSError:
            try:
                staging.unlink(missing_ok=True)
            except OSError:
                pass
            return None
        self.seen.add(destination.name)
        return destination
