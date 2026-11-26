"""Build input plans for the installed Minimalism levels."""

from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
import argparse
import json
import time

from planner import Planner
from beam import plan_beam, plan_chase
from platforms import plan_platforms
from search_memory import SearchMemory


def plan_room(level, geometry, directory, attempts, nodes, seconds, overwrite, include_letters, learning):
    output = directory / f"planner-room-{level}.txt"
    if output.is_file() and not overwrite:
        return level, output.stat().st_size, None, 0.0
    started = time.monotonic()
    planner = Planner.from_export(geometry, level, include_letters=include_letters)
    if learning:
        planner.search_memory = SearchMemory(learning / str(level))
        planner.search_memory.load()
        for record in sorted((learning / str(level)).glob("*.json")):
            death = json.loads(record.read_text(encoding="utf-8"))
            planner.avoid_death(death["cause"], death["x"], death["y"], death["tick"])
    strategies = (
        (planner.plan, nodes),
        (planner.plan_hierarchical, min(nodes, 18000)),
        (planner.plan_ordered, min(nodes, 18000)),
    )

    def save(controls, method):
        staging = output.with_name(f"{output.stem}-{time.time_ns()}.tmp")
        staging.write_text("".join(map(str, controls)), encoding="ascii")
        staging.replace(output)
        return level, len(controls), method, time.monotonic() - started

    if planner.dynamic and planner.dynamic.chase:
        controls = plan_chase(planner, seconds=seconds)
        if controls:
            return save(controls, "chase")

    for attempt in attempts:
        for solver, budget in strategies:
            controls = solver(attempt=attempt, max_nodes=budget, deadline=time.monotonic() + seconds)
            if controls:
                return save(controls, f"{solver.__name__}/{attempt}")
        platform_route = plan_platforms(planner, max_nodes=min(nodes, 2500), attempt=attempt,
                                        deadline=time.monotonic() + seconds)
        if platform_route:
            return save(platform_route, f"platforms/{attempt}")
        print(f"{level} attempt {attempt} exhausted after {time.monotonic() - started:.1f}s", flush=True)
    controls = plan_beam(planner, seconds=seconds)
    if controls:
        return save(controls, "beam")
    return level, 0, None, time.monotonic() - started


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("geometry", type=Path)
    parser.add_argument("levels", type=int, nargs="+")
    parser.add_argument("--attempts", type=int, nargs="+", default=[0, 1, 2, 3, 5, 8, 9, 11])
    parser.add_argument("--nodes", type=int, default=90000)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--plan-timeout", type=float, default=30, help="Seconds allowed per offline route strategy")
    parser.add_argument("--keys-only", action="store_true", help="Generate comparison routes without collecting symbols")
    parser.add_argument("--learning", type=Path, help="Collision observations for this exact game build")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    if not 0 < args.plan_timeout <= 300:
        parser.error("Planning timeout must be 0–300 seconds.")
    args.output.mkdir(parents=True, exist_ok=True)
    pending = list(dict.fromkeys(args.levels))
    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        for round_index, attempt in enumerate(args.attempts):
            if not pending:
                break
            # Give every room a turn before spending longer on any unsolved room.
            seconds = min(args.plan_timeout, 6.0 * (round_index + 1))
            tasks = [executor.submit(plan_room, level, args.geometry, args.output, [attempt], args.nodes, seconds,
                                     args.overwrite and round_index == 0, not args.keys_only, args.learning)
                     for level in pending]
            unresolved = set()
            for task in as_completed(tasks):
                level, frames, method, elapsed = task.result()
                print(f"{level}: {frames} frames via {method} in {elapsed:.1f}s", flush=True)
                if not frames:
                    unresolved.add(level)
            pending = [level for level in pending if level in unresolved]
    if pending:
        print("No prepared route for " + ", ".join(map(str, pending)), flush=True)


if __name__ == "__main__":
    main()
