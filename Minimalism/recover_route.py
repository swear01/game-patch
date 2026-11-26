"""Prepare a route from a live Minimalism checkpoint and its captured inputs."""

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
from tempfile import NamedTemporaryFile
from time import monotonic

from beam import plan_beam, plan_chase
from planner import Planner, State
from platforms import plan_platforms


CONTROL = re.compile(r"[012456]+")
MAX_REPLAY_DRIFT = 16


@dataclass
class Attempt:
    checkpoints: list
    controls: bytearray


@dataclass
class Seed:
    attempt: Attempt
    index: int
    remaining: frozenset

    @property
    def checkpoint(self):
        return self.attempt.checkpoints[self.index]


def read_run(path):
    with path.open("rb") as stream:
        for line in stream:
            # The recorder may still be writing its last line.
            if line.endswith(b"\n") and line.strip():
                entry = json.loads(line)
                if entry["event"] == "checkpoint":
                    for name in ("keys", "symbols", "shooters", "falling"):
                        entry[name] = {int(key): value for key, value in entry.get(name, {}).items()}
                    entry.setdefault("arrows", [])
                yield entry


def gather_seeds(records, level, required_ids):
    commands = {entry["sequence"]: entry["command"] for entry in records
                if entry["event"] == "input" and entry["level"] == level}
    attempt = None
    seeds = []
    for checkpoint in records:
        if checkpoint["event"] != "checkpoint":
            continue
        if checkpoint["level"] != level or "player" not in checkpoint:
            attempt = None
            continue
        tick = checkpoint["tick"]
        remaining = required_ids.intersection(checkpoint["keys"].keys() | checkpoint["symbols"].keys())
        if tick == 0:
            attempt = Attempt([checkpoint], bytearray()) if remaining == required_ids else None
        elif attempt:
            previous = attempt.checkpoints[-1]
            command = commands.get(previous["sequence"], "")
            steps = tick - previous["tick"]
            if (checkpoint["sequence"] != previous["sequence"] + 1
                    or not CONTROL.fullmatch(command) or not 0 < steps <= len(command)):
                attempt = None
                continue
            attempt.controls.extend(command[:steps].encode("ascii"))
            attempt.checkpoints.append(checkpoint)
        if attempt:
            seeds.append(Seed(attempt, len(attempt.checkpoints) - 1, frozenset(remaining)))
    return seeds


def rank_seeds(seeds, estimates=None):
    def rank(seed):
        snapshot = seed.checkpoint
        player = snapshot["player"]
        danger = len(snapshot["arrows"]) + sum(0 < delay <= 30 for delay in snapshot["shooters"].values())
        danger += sum(bool(trap[2]) for trap in snapshot["falling"].values())
        steady = not player["grounded"] or player["state"] != 0
        position = State.from_telemetry(player)
        distances = [estimates[item](position) for item in seed.remaining if estimates and estimates.get(item)]
        nearest = min(distances, default=0)
        return (len(seed.remaining), danger, player["invert_gravity"] != 1, steady,
                nearest, abs(player["vspd"]), snapshot["tick"])

    seen = set()
    for seed in sorted(seeds, key=rank):
        player = seed.checkpoint["player"]
        pose = (seed.remaining, round(player["x"] / 32), round(player["y"] / 32),
                round(player["hspd"] / 2), player["state"], player["invert_gravity"])
        if pose not in seen:
            seen.add(pose)
            yield seed


def initialize(planner, checkpoint):
    state = State.from_telemetry(checkpoint["player"])
    state.tick = checkpoint["tick"]
    planner.with_remaining_keys(state, checkpoint["keys"].keys() | checkpoint["symbols"].keys())
    planner.observe(checkpoint)
    return state


def replay_prefix(planner, seed, deadline):
    snapshots = seed.attempt.checkpoints[:seed.index + 1]
    controls = seed.attempt.controls
    deviation = 0
    for previous, current in zip(snapshots, snapshots[1:]):
        if monotonic() >= deadline:
            return None
        state = initialize(planner, previous)
        for offset, press in enumerate(controls[previous["tick"]:current["tick"]]):
            if offset % 64 == 0 and monotonic() >= deadline:
                return None
            state = planner.step(state, press - 48)
            if state is None:
                return None
        observed = current["player"]
        deviation = max(deviation, abs(state.x - observed["x"]), abs(state.y - observed["y"]))
    return deviation


def solve(planner, state, method, nodes, seconds):
    if method == "ordered":
        return planner.plan_ordered(state, max_nodes=nodes, deadline=monotonic() + seconds)
    if method == "platform":
        return plan_platforms(
            planner, state, max_nodes=max(100, nodes // 3), wall_nodes=True, ordered=True,
            deadline=monotonic() + seconds,
        )
    if method == "chase":
        return plan_chase(planner, state, nodes=nodes, seconds=seconds)
    return plan_beam(planner, state, nodes=nodes, seconds=seconds)


def trim_at_exit(planner, checkpoint, controls, deadline):
    state = initialize(planner, checkpoint)
    for frame, press in enumerate(controls, 1):
        if frame % 64 == 1 and monotonic() >= deadline:
            return None
        state = planner.step(state, int(press))
        if state is None:
            return None
        if state.finished:
            return "".join(map(str, controls[:frame]))
    return None


def write_candidate(path, presses):
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile("w", dir=path.parent, prefix=path.name + ".", suffix=".tmp",
                            encoding="ascii", delete=False) as stream:
        stream.write(presses)
        staged = Path(stream.name)
    try:
        staged.replace(path)
    finally:
        staged.unlink(missing_ok=True)


def recover(args):
    deadline = monotonic() + args.seconds
    planner = Planner.from_export(args.rooms, args.level, include_letters=not args.keys_only)
    required = set(planner.required_ids)
    collected = set(args.collected)
    if not collected <= required:
        raise SystemExit(f"Requested collected IDs are not tracked in this room: {sorted(collected - required)}")
    seeds = [seed for seed in gather_seeds(list(read_run(args.run)), args.level, required)
             if seed.remaining.isdisjoint(collected)
             and (args.seed_sequence is None or seed.checkpoint["sequence"] == args.seed_sequence)]
    estimates = {item: planner._distance_estimate(goal, supported=True, deadline=deadline)
                 for item, goal in zip(planner.required_ids, planner.keys)
                 if any(item in seed.remaining for seed in seeds)}
    ranked = list(rank_seeds(seeds, estimates))[:args.candidates * 3]
    ranked.sort(key=lambda seed: (
        len(seed.remaining),
        not planner._can_continue(initialize(planner, seed.checkpoint), 20),
    ))
    ranked = ranked[:args.candidates]
    if not ranked:
        raise SystemExit("No alive checkpoints with a complete input prefix from a fresh room attempt.")
    for seed in ranked:
        print(f"Checkpoint {seed.checkpoint['sequence']} at step {seed.checkpoint['tick']}, "
              f"{len(seed.remaining)} pickups left.", flush=True)
    if args.rank_only:
        return
    methods = args.algorithms or (("chase", "ordered", "beam") if planner.chase_room
                                  else ("ordered", "beam", "platform"))
    for index, seed in enumerate(ranked):
        deviation = replay_prefix(planner, seed, deadline)
        if deviation is None:
            print(f"Checkpoint {seed.checkpoint['sequence']}: model rejected the captured prefix.", flush=True)
            continue
        if deviation > MAX_REPLAY_DRIFT:
            print(f"Checkpoint {seed.checkpoint['sequence']}: captured prefix drifted {deviation:.1f} px; skipping.",
                  flush=True)
            continue
        checkpoint = seed.checkpoint
        for method_index, method in enumerate(methods):
            remaining = deadline - monotonic()
            if remaining <= 0:
                raise SystemExit("Preparation budget expired before finding a candidate.")
            searches = (len(ranked) - index - 1) * len(methods) + len(methods) - method_index
            state = initialize(planner, checkpoint)
            suffix = solve(planner, state, method, args.nodes, remaining / searches)
            tail = trim_at_exit(planner, checkpoint, suffix, deadline) if suffix else None
            if tail:
                prefix = seed.attempt.controls[:checkpoint["tick"]].decode("ascii")
                write_candidate(args.output, prefix + tail)
                print(f"Prepared {len(prefix) + len(tail)} steps via {method} from checkpoint "
                      f"{checkpoint['sequence']}: {len(prefix)} captured + {len(tail)} planned. "
                      f"Largest replay position difference: {deviation:.1f} px.", flush=True)
                return
    raise SystemExit("No room-completing route within the allotted preparation time.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rooms", type=Path)
    parser.add_argument("run", type=Path)
    parser.add_argument("level", type=int, choices=range(1, 32))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--seconds", type=float, default=90)
    parser.add_argument("--nodes", type=int, default=18000)
    parser.add_argument("--candidates", type=int, default=4)
    parser.add_argument("--algorithms", nargs="+", choices=("ordered", "beam", "platform", "chase"))
    parser.add_argument("--collected", type=int, nargs="+", default=(),
                        help="Only consider checkpoints that have already picked up these instance IDs")
    parser.add_argument("--seed-sequence", type=int, help="Use one recorded checkpoint sequence")
    parser.add_argument("--keys-only", action="store_true")
    parser.add_argument("--rank-only", action="store_true")
    args = parser.parse_args()
    if not (0 < args.seconds <= 900 and args.nodes > 0 and args.candidates > 0):
        parser.error("Use positive search limits and a time budget of at most 900 seconds.")
    if not args.rank_only and args.output is None:
        parser.error("Provide --output to save a prepared route, or --rank-only to inspect seeds.")
    recover(args)


if __name__ == "__main__":
    main()
