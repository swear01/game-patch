"""Build an isolated Minimalism playtest and play its campaign using native controls."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import uuid

from planner import ACTIONS, Planner, State
from arrow_shelter import detour_for_arrows
from search_memory import SearchMemory, context_key


SCRIPT_DIR = Path(__file__).resolve().parent
PREFIX = "minimalism-playtest-"
APP_ID = "585690"
STATE_NAMES = (
    "x", "y", "hspd", "vspd", "grounded", "state", "jumps", "wall_jumps",
    "meet", "wall_jump_can", "invert_gravity", "first_alarm", "second_alarm",
)


def prepare(args, session, save_name):
    cabinet = session / "game.cab"
    runtime = session / "game"
    runtime.mkdir()
    data = args.game.read_bytes()
    # The installed launcher is an IExpress executable with one embedded CAB.
    offset = data.find(b"MSCF\x00\x00\x00\x00")
    if offset < 0:
        raise RuntimeError("Expected the original Steam IExpress executable.")
    size = int.from_bytes(data[offset + 8 : offset + 12], "little")
    if not 0 < size <= len(data) - offset:
        raise RuntimeError("The embedded cabinet is truncated.")
    cabinet.write_bytes(data[offset : offset + size])
    subprocess.run(["expand.exe", "-F:*", str(cabinet), str(runtime)], check=True, capture_output=True)
    (runtime / "steam_appid.txt").write_text(APP_ID, encoding="ascii")
    waiter = SCRIPT_DIR / "minimalism_wait32.dll"
    if waiter.is_file():
        shutil.copy2(waiter, runtime / waiter.name)
    if args.speed == 5:
        options = runtime / "options.ini"
        settings = options.read_text(encoding="ascii")
        options.write_text(settings.replace("AlternateSyncMethod=0", "AlternateSyncMethod=1").replace("SleepMargin=1", "SleepMargin=15"), encoding="ascii")
    rooms = session / "rooms.json"
    original = runtime / "data.win"
    modified = runtime / "test.win"
    environment = {
        **os.environ,
        "MINIMALISM_TEST_RATE": str(60 * args.speed),
        "MINIMALISM_TEST_FOLDER": save_name,
        "MINIMALISM_TEST_START": str(args.start_level),
        "MINIMALISM_TEST_SLOT": str(args.slot),
        "MINIMALISM_TEST_SYMBOLS": "0" if args.keys_only else "1",
        "MINIMALISM_TEST_STEAM": "1" if args.steam_achievements else "0",
        "MINIMALISM_TEST_WAIT_DLL": "1" if waiter.is_file() else "0",
        "MINIMALISM_ROOM_METADATA": str(rooms),
    }
    with (session / "build.log").open("w", encoding="utf-8") as build_log:
        for script, arguments in (("ExportRooms.csx", []), ("Instrument.csx", ["-o", str(modified)])):
            subprocess.run(
                [str(args.umt), "load", str(original), "-s", script, *arguments],
                cwd=SCRIPT_DIR, env=environment, check=True, stdout=build_log, stderr=subprocess.STDOUT,
            )
    modified.replace(original)
    return runtime, json.loads(rooms.read_text(encoding="utf-8-sig")), hashlib.sha256(data).hexdigest()[:16]


def read_state(path):
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (FileNotFoundError, PermissionError):
        return None
    if not lines or lines[-1] != "end":
        return None
    level, tick, _, action, *rates = lines[0].split(",")
    level, tick, action = int(level), int(tick), int(action)
    result = {"level": level, "tick": tick, "keys": {}, "symbols": {}, "shooters": {}, "arrows": [],
              "falling": {}, "pistons": {}}
    if rates:
        result.update(target_rate=int(rates[0]), measured_rate=float(rates[1]))
    if len(rates) > 2:
        result["window"] = list(map(int, rates[2:6]))
    if len(rates) > 6:
        result["focused"] = bool(int(rates[6]))
    if len(rates) > 7:
        result["previous_symbols"] = int(rates[7])
    if len(rates) > 8 and rates[8] != "-1":
        result["previous_achievement"] = bool(int(rates[8]))
    for line in lines[1:-1]:
        first, *values = line.split(",")
        if first == "key":
            result["keys"][int(values[0])] = tuple(map(float, values[1:]))
        elif first == "symbol":
            result["symbols"][int(values[0])] = tuple(map(float, values[1:]))
        elif first == "shooter":
            result["shooters"][int(values[0])] = int(values[1])
        elif first == "arrow":
            result["arrows"].append(tuple(map(float, values)))
        elif first == "falling":
            result["falling"][int(values[0])] = tuple(map(float, values[1:]))
        elif first == "piston":
            result["pistons"][int(values[0])] = tuple(map(float, values[1:]))
        elif first == "death":
            result["death"] = values
        else:
            x, y, hspd, vspd = map(float, [first, *values[:3]])
            fields = (x, y, hspd, vspd, *map(int, values[3:]))
            result["player"] = dict(zip(STATE_NAMES, fields, strict=True))
            result["player"].update(tick=tick, jump_held=bool(action & 4), gravity_remaining=max(0, fields[-1]))
    return result


def wait_for_state(folder, seq, process):
    checkpoint = folder / f"{PREFIX}state-{seq}.txt"
    ending = folder / f"{PREFIX}finished.txt"
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        if ending.exists():
            lines = ending.read_text(encoding="ascii").splitlines()
            if lines and lines[0] == "rm_level_end" and len(lines) > 1 and lines[1].isdigit():
                result = {"ending": True, "previous_symbols": int(lines[1])}
                if len(lines) > 2 and lines[2] in ("0", "1"):
                    result["previous_achievement"] = lines[2] == "1"
                return result
        state = read_state(checkpoint)
        if state is not None:
            return state
        if process is not None and process.poll() is not None:
            raise RuntimeError(f"The game exited with code {process.returncode} before checkpoint {seq}.")
        time.sleep(0.025)
    raise TimeoutError(f"No game response at checkpoint {seq}.")


def send(folder, seq, controls):
    target = folder / f"{PREFIX}move-{seq}.txt"
    temporary = target.with_suffix(".tmp")
    temporary.write_text(controls, encoding="ascii")
    temporary.replace(target)


def safe_recovery(planner, player, objective, visits):
    goal = planner.goal if objective in (None, -1) else planner.keys[objective]
    goal_x = (goal.left + goal.right) / 2
    goal_y = (goal.top + goal.bottom) / 2
    options = []
    for action in ACTIONS:
        future = player
        for _ in range(12):
            future = planner.step(future, action)
            if future is None:
                break
        if future is not None and planner._can_continue(future, 8):
            position = (round(future.x / 32), round(future.y / 32), future.keys, future.invert_gravity)
            distance = abs(future.x - goal_x) + abs(future.y - goal_y)
            options.append((visits[position], distance, action, future))
    if not options:
        return None
    _, _, action, prediction = min(options, key=lambda option: option[:3])
    return str(action) * 12, prediction


def waiting_route(args, level, tried, trials=None, prefer_prepared=False):
    routes = (("verified", args.verified), ("prepared", args.cache))
    for source, directory in (reversed(routes) if prefer_prepared else routes):
        if directory is None:
            continue
        path = directory / f"planner-room-{level}.txt"
        if path.exists():
            candidate = path.read_text(encoding="ascii").strip()
            if candidate and (candidate not in tried or (trials is not None and trials[candidate] < 16)):
                return source, candidate
    return None


def retime_route(planner, player, planned, trajectory, deadline):
    if planner.dynamic is None or not trajectory:
        return None
    anchors = [(0, player), *enumerate(trajectory, 1)]
    anchors = [(index, pose) for index, pose in anchors
               if pose.grounded and abs(pose.hspd) < 1 and abs(pose.vspd) < 1]
    horizon = min(len(planned), len(trajectory) + 36)
    for index, pose in reversed(anchors[-5:]):
        settled = pose
        for delay in range(1, 113):
            settled = planner.step(settled, 0)
            if (settled is None or abs(settled.x - pose.x) > 2 or abs(settled.y - pose.y) > 2
                    or settled.invert_gravity != pose.invert_gravity):
                break
            if delay not in (6, 12, 20, 30, 42, 52, 66, 84, 112):
                continue
            if time.monotonic() >= deadline:
                return None
            check = settled
            for action in planned[index:horizon]:
                check = planner.step(check, int(action))
                if check is None:
                    break
            if check is not None:
                return planned[:index] + "0" * delay + planned[index:], delay
    return None


def steer_around(planner, player, planned, trajectory, deadline):
    if len(trajectory) < 5:
        return None
    danger = len(trajectory)
    horizon = min(len(planned), danger + 56)
    for lead in (3, 6, 12, 20, 32, 49):
        cut = max(0, danger - lead)
        start = trajectory[cut - 1] if cut else player
        for adjustment in ("jump", "release", 0, 1, 2):
            for width in (1, 3, 5):
                if time.monotonic() >= deadline:
                    return None
                previous = planned[cut:cut + width]
                if adjustment == "jump":
                    replacement = "".join(str(int(action) | 4) for action in previous)
                elif adjustment == "release":
                    replacement = "".join(str(int(action) & 3) for action in previous)
                else:
                    replacement = "".join(str((int(action) & 4) | adjustment) for action in previous)
                if replacement == planned[cut:cut + width]:
                    continue
                candidate = replacement + planned[cut + width:horizon]
                state = start
                for action in candidate:
                    state = planner.step(state, int(action))
                    if state is None or state.finished:
                        break
                if state is not None:
                    return planned[:cut] + replacement + planned[cut + width:]
    return None


def play(args, session, folder, export, process, build):
    seq = args.sequence
    current_level = 0
    planner = None
    attempts = 0
    misses = 0
    plan_tail = ""
    native_tail = ""
    executed = []
    tried_caches = set()
    route_trials = Counter()
    native_trials = Counter()
    learned = set()
    visits = Counter()
    objective = None
    objective_keys = None
    previous_remaining = float("inf")
    last_pickup = time.monotonic()
    next_retarget = last_pickup + 8
    retargets = 0
    predicted = None
    lookahead = None
    deaths = 0
    started = time.monotonic()
    command_sent = started
    states = args.resume_log or session / "run.jsonl"
    if args.resume_log:
        with states.open(encoding="utf-8") as stream:
            first = json.loads(stream.readline())
        started -= time.time() - first["time"] + first["elapsed"]
    learning = args.learning / build

    def log(event, **data):
        with states.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"event": event, "time": round(time.time(), 3), "elapsed": round(time.monotonic() - started, 3), **data}) + "\n")

    def shelter(player, controls, trajectory, deadline):
        danger = player.tick + len(trajectory) + 1
        replacement = detour_for_arrows(planner, player, list(map(int, controls)), danger,
                                        min(deadline, time.monotonic() + 1.9))
        if replacement:
            log("arrow_shelter", level=current_level, tick=player.tick, danger_at=danger)
            return "".join(map(str, replacement))
        return None

    if args.attach:
        log("controller_resumed", sequence=seq)

    def clear(level, checkpoint):
        symbol_file = folder / f"{PREFIX}symbols.txt"
        pickups = {}
        if not args.keys_only:
            missing = checkpoint.get("previous_symbols")
            if missing:
                raise RuntimeError(f"Room {level} reached the next room with {missing} symbols left.")
            expected = {item["id"] for item in planner.room["instances"]
                        if item["name"] in ("obj_bonus_jp", "obj_bonus_eng")}
            if symbol_file.exists():
                for line in symbol_file.read_text(encoding="ascii").splitlines():
                    room, tick, instance, index, alphabet = line.split(",")
                    if int(room) == level:
                        pickups[int(instance)] = {"index": int(index), "alphabet": alphabet, "tick": int(tick)}
            if expected != set(pickups):
                raise RuntimeError(f"Room {level} is missing native pickup evidence for {expected - set(pickups)}.")
        if args.verified and executed:
            destination = args.verified / f"planner-room-{level}.txt"
            route = "".join(executed)
            if not destination.exists() or len(route) < destination.stat().st_size:
                temporary = args.verified / f"{session.name}-{level}.tmp"
                temporary.write_text(route, encoding="ascii")
                temporary.replace(destination)
        log("clear", level=level, symbols=pickups, steam_achievement=checkpoint.get("previous_achievement"))
        suffix = "" if args.keys_only else f" ({len(pickups)} symbols)."
        print(f"Room {level} cleared{suffix or '.'}", flush=True)

    while True:
        checkpoint = wait_for_state(folder, seq, process)
        if checkpoint.get("ending"):
            if current_level != 31:
                raise RuntimeError(f"Unexpected ending after room {current_level}.")
            clear(current_level, checkpoint)
            log("ending", room="rm_level_end", deaths=deaths)
            print(f"Room 31 cleared. Game reached rm_level_end after {deaths} deaths.", flush=True)
            return

        level = checkpoint["level"]
        log("checkpoint", sequence=seq, seconds_after_command=round(time.monotonic() - command_sent, 3), **checkpoint)
        if level != current_level:
            if current_level:
                if level != current_level + 1:
                    raise RuntimeError(f"Unexpected room change {current_level} → {level}.")
                clear(current_level, checkpoint)
                if current_level == args.stop_after_level:
                    log("segment_complete", level=current_level, deaths=deaths)
                    return
            elif not args.attach and level != args.start_level:
                raise RuntimeError(f"Expected to start in room {args.start_level}, arrived in room {level}.")
            current_level, attempts, misses, plan_tail, predicted = level, 0, 0, "", None
            native_tail = ""
            lookahead = None
            executed.clear()
            tried_caches.clear()
            route_trials.clear()
            native_trials.clear()
            learned.clear()
            visits.clear()
            objective = objective_keys = None
            previous_remaining, last_pickup = float("inf"), time.monotonic()
            next_retarget, retargets = last_pickup + 8, 0
            planner = Planner.from_export(export, level, include_letters=not args.keys_only)
            planner.search_memory = SearchMemory(learning / str(level))
        feedback = learning / str(level)
        observations = planner.search_memory.load()
        if observations:
            log("search_memory_applied", level=level, count=observations)
        for record in feedback.glob("*.json"):
            if record.name not in learned:
                observation = json.loads(record.read_text(encoding="utf-8"))
                planner.avoid_death(observation["cause"], observation["x"], observation["y"], observation["tick"])
                learned.add(record.name)
                log("learning_applied", level=level, cause=observation["cause"], record=record.name)

        if "player" not in checkpoint:
            deaths += 1
            print(f"Room {level}, frame {checkpoint['tick']}: death {checkpoint.get('death', [])}; retrying.", flush=True)
            plan_tail, predicted = "", None
            native_tail = ""
            lookahead = None
            cause = checkpoint.get("death", [])
            if len(cause) == 3:
                hazard, x, y = cause
                tick = checkpoint["tick"]
                planner.avoid_death(hazard, x, y, tick)
                feedback.mkdir(parents=True, exist_ok=True)
                record = feedback / f"{session.name}-{seq}.json"
                staging = record.with_suffix(".tmp")
                staging.write_text(json.dumps({"cause": hazard, "x": float(x), "y": float(y), "tick": tick}), encoding="utf-8")
                staging.replace(record)
                learned.add(record.name)
                log("learned", level=level, cause=hazard, x=float(x), y=float(y), tick=tick)
            if args.trace:
                return
            command = "retry"
        else:
            player = State.from_telemetry(checkpoint["player"])
            if player.tick == 0:
                executed.clear()
                if args.verified and not args.trace and not checkpoint["shooters"]:
                    route = waiting_route(args, level, tried_caches)
                    if route and route[0] == "verified" and native_trials[route[1]] < 2:
                        candidate = route[1]
                        if re.fullmatch("[012456]+", candidate):
                            native_trials[candidate] += 1
                            native_tail, plan_tail, predicted, lookahead = candidate + "0" * 14, "", None, None
                            log("native_replay", level=level, steps=len(candidate), retry=native_trials[candidate])
            if native_tail:
                size = args.batch_steps or len(native_tail)
                command, native_tail = native_tail[:size], native_tail[size:]
                executed.append(command)
                log("input", sequence=seq, level=level, command=command)
                send(folder, seq, command)
                seq += 1
                command_sent = time.monotonic()
                continue
            remaining = set(checkpoint["keys"])
            if not args.keys_only:
                remaining.update(checkpoint["symbols"])
            if player.tick == 0 or len(remaining) < previous_remaining:
                last_pickup = time.monotonic()
                next_retarget, retargets = last_pickup + 8, 0
            previous_remaining = len(remaining)
            planner.with_remaining_keys(player, remaining)
            planner.observe(checkpoint)
            if predicted and (abs(predicted.x - player.x) > 16 or abs(predicted.y - player.y) > 16):
                log("divergence", level=level, tick=player.tick, expected=[predicted.x, predicted.y], actual=[player.x, player.y])
                if not args.trace:
                    plan_tail = ""
            if lookahead and not plan_tail:
                forecast, controls, finished = lookahead
                if (player.tick == forecast.tick and player.keys == forecast.keys
                    and player.invert_gravity == forecast.invert_gravity
                    and abs(player.x - forecast.x) <= 4 and abs(player.y - forecast.y) <= 4
                    and abs(player.hspd - forecast.hspd) <= 2 and abs(player.vspd - forecast.vspd) <= 2):
                    plan_tail = controls + ("0" * 14 if finished else "")
                    log("lookahead_used", level=level, tick=player.tick, steps=len(plan_tail))
            lookahead = None
            deadline = time.monotonic() + args.plan_timeout
            while True:
                if not plan_tail:
                    if time.monotonic() >= deadline:
                        log("planning_timeout", level=level, tick=player.tick, seconds=args.plan_timeout)
                        print(f"Room {level}: planning timed out after {args.plan_timeout:g}s.", flush=True)
                        misses += 1
                        recovery = safe_recovery(planner, player, objective, visits)
                        if recovery:
                            command, predicted = recovery
                            executed.append(command)
                        else:
                            command, predicted = "restart", None
                        break
                    if misses >= args.attempts:
                        raise RuntimeError(f"Room {level} stalled after {misses} failed routes. Check {states}.")
                    complete = True
                    source = "calculated"
                    if player.tick == 0 or time.monotonic() - last_pickup > 8:
                        retries = route_trials if checkpoint["shooters"] else None
                        ready = waiting_route(args, level, tried_caches, retries,
                                              prefer_prepared=bool(checkpoint["shooters"]))
                        if ready and player.tick != 0:
                            log("fresh_route_restart", level=level, tick=player.tick, source=ready[0])
                            print(f"Room {level}: switching to a newly prepared route.", flush=True)
                            command, predicted = "restart", None
                            break
                        if ready:
                            source, plan_tail = ready
                            tried_caches.add(plan_tail)
                            route_trials[plan_tail] += 1
                    if not plan_tail:
                        now = time.monotonic()
                        retarget = now >= next_retarget
                        if retarget:
                            next_retarget = now + 6
                            retargets += 1
                            position = (round(player.x / 32), round(player.y / 32), player.keys, player.invert_gravity)
                            if objective is not None and visits[position] > 1:
                                goal = planner.goal if objective == -1 else planner.keys[objective]
                                phase = planner.dynamic.phase(player) if planner.dynamic else 0
                                key = context_key(player, goal, remaining=planner.all_keys & ~player.keys, phase=phase)
                                planner.search_memory.record(key)
                                log("search_stall_learned", level=level, tick=player.tick, objective=objective,
                                    penalty=planner.search_memory.penalty(key))
                        variation = (attempts + max(0, args.slot - 1) * 2) % 8 + (retargets + misses // 3) * 8
                        if objective_keys != player.keys or retarget or (misses > 0 and misses % 3 == 0):
                            order = planner.objective_order(player, attempt=variation, deadline=deadline)
                            alternative = next((item for item in order if item != objective), None) if retarget else None
                            objective = alternative if alternative is not None else (order[0] if order else None)
                            objective_keys = player.keys
                            if retarget:
                                log("retarget", level=level, tick=player.tick, objective=objective)
                        position = (round(player.x / 32), round(player.y / 32), player.keys, player.invert_gravity)
                        visits[position] += 1
                        if retargets and (not remaining or visits[position] % 4 == 0):
                            plan = planner.plan_ordered(player, max_nodes=min(args.search_nodes, 18000), attempt=variation,
                                                        deadline=deadline)
                        elif misses % 3 == 2 or visits[position] % 5 == 0:
                            plan = planner.plan(player, max_nodes=args.search_nodes, attempt=variation, deadline=deadline)
                        else:
                            segment = planner.plan_segment(player, max_nodes=min(args.search_nodes, 20000),
                                                           attempt=variation, min_steps=18, objective=objective,
                                                           supported=bool(retargets % 2),
                                                           deadline=deadline, shared_search=bool(retargets))
                            plan, complete = (segment[0], segment[1].finished) if segment else (None, False)
                        if plan:
                            plan_tail = "".join(map(str, plan))
                    attempts += 1
                    if not plan_tail:
                        misses += 1
                        if player.tick > 0 and misses % 6 == 0 and time.monotonic() < deadline:
                            command, predicted = "restart", None
                            print(f"Room {level}: restarting after an unsafe route.", flush=True)
                            break
                        continue
                    if not re.fullmatch("[012456]+", plan_tail):
                        raise RuntimeError(f"Invalid input plan in room {level}.")
                    if complete:
                        plan_tail += "0" * 14
                    print(f"Room {level}, route {attempts}: {len(plan_tail)} steps, {len(remaining)} pickups left.", flush=True)
                    log("route", level=level, tick=player.tick, route=attempts, steps=len(plan_tail), complete=complete, source=source)
                size = args.batch_steps or len(plan_tail)
                command, plan_tail = plan_tail[:size], plan_tail[size:]
                predicted = player
                goal_reached = False
                trajectory = []
                for index, action in enumerate(command):
                    predicted = planner.step(predicted, int(action))
                    if predicted is None:
                        break
                    trajectory.append(predicted)
                    goal_reached |= predicted.finished
                if predicted is not None or goal_reached or args.trace:
                    arrow_horizon = 160 if len(checkpoint["shooters"]) > 1 else 80
                    look_forward = (predicted is not None and not goal_reached and not args.trace
                                    and plan_tail and checkpoint["shooters"]
                                    and (checkpoint["arrows"] or min(checkpoint["shooters"].values()) < size + arrow_horizon))
                    if look_forward:
                        future = predicted
                        for action in plan_tail[:arrow_horizon]:
                            future = planner.step(future, int(action))
                            if future is None or future.finished:
                                break
                            trajectory.append(future)
                        if future is None:
                            repair_deadline = min(deadline, time.monotonic() + 0.22)
                            repair = retime_route(planner, player, command + plan_tail, trajectory, repair_deadline)
                            if repair:
                                plan_tail, delay = repair
                                log("route_retimed", level=level, tick=player.tick, delay=delay)
                                continue
                            correction = shelter(player, command + plan_tail, trajectory, deadline)
                            if correction:
                                plan_tail = correction
                                continue
                            correction = steer_around(planner, player, command + plan_tail, trajectory, repair_deadline)
                            if correction:
                                plan_tail = correction
                                log("route_steered", level=level, tick=player.tick)
                                continue
                    executed.append(command)
                    misses = 0
                    break
                log("unsafe_batch", level=level, tick=player.tick, danger_at=player.tick + index + 1)
                misses += 1
                repair = retime_route(planner, player, command + plan_tail, trajectory,
                                      min(deadline, time.monotonic() + 0.28))
                if repair:
                    plan_tail, delay = repair
                    log("route_retimed", level=level, tick=player.tick, delay=delay)
                    continue
                correction = shelter(player, command + plan_tail, trajectory, deadline)
                if correction:
                    plan_tail = correction
                    continue
                correction = steer_around(planner, player, command + plan_tail, trajectory,
                                          min(deadline, time.monotonic() + 0.17))
                if correction:
                    plan_tail = correction
                    log("route_steered", level=level, tick=player.tick)
                    continue
                plan_tail = ""
                if len(trajectory) >= 24:
                    safe = len(trajectory) - 12
                    command, predicted = command[:safe], trajectory[safe - 1]
                    executed.append(command)
                    log("safe_prefix", level=level, tick=player.tick, steps=safe)
                    break
        log("input", sequence=seq, level=level, command=command)
        send(folder, seq, command)
        seq += 1
        command_sent = time.monotonic()
        if command.isdigit() and not plan_tail and predicted and not predicted.finished and not args.trace:
            # Search from the predicted end of the batch while the game is executing it.
            seconds = min(args.plan_timeout, 0.35, len(command) / (60 * args.speed))
            next_goal = objective if predicted.keys == player.keys else None
            segment = planner.plan_segment(predicted, max_nodes=6500, attempt=attempts % 8,
                                           min_steps=18, objective=next_goal, supported=bool(retargets % 2),
                                           deadline=command_sent + seconds)
            if segment and segment[0]:
                controls, destination = segment
                lookahead = predicted, "".join(map(str, controls)), destination.finished


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=lambda s: Path(s).resolve())
    parser.add_argument("--umt", type=lambda s: Path(s).resolve(), help="Path to UndertaleModCli.exe")
    parser.add_argument("--speed", type=int, choices=(1, 5), default=5)
    parser.add_argument("--keys-only", action="store_true", help="Run a door-only comparison without requiring symbols")
    parser.add_argument("--steam-achievements", action="store_true", help="Allow the main lane to keep the game's native Steam awards")
    parser.add_argument("--work", type=lambda s: Path(s).resolve(), required=True)
    parser.add_argument("--cache", type=lambda s: Path(s).resolve(), help="Optional room input plans")
    parser.add_argument("--verified", type=lambda s: Path(s).resolve(), help="Share routes actually cleared by running games")
    parser.add_argument("--learning", type=lambda s: Path(s).resolve(), help="Share collision observations across playtests")
    parser.add_argument("--attempts", type=int, default=40)
    parser.add_argument("--search-nodes", type=int, default=75000)
    parser.add_argument("--plan-timeout", type=float, default=2.5, help="Seconds allowed to plan at a checkpoint")
    parser.add_argument("--batch-steps", type=int, default=96, help="Steps between position checks (0 sends full routes)")
    parser.add_argument("--start-level", type=int, choices=range(1, 32), default=1, help=argparse.SUPPRESS)
    parser.add_argument("--stop-after-level", type=int, choices=range(1, 32), default=31, help=argparse.SUPPRESS)
    parser.add_argument("--slot", type=int, choices=range(5), default=0, help=argparse.SUPPRESS)
    parser.add_argument("--trace", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--attach", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--export", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--sequence", type=int, default=0, help=argparse.SUPPRESS)
    parser.add_argument("--resume-log", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--resume-build", default="attached", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.steam_achievements and (args.slot > 1 or args.start_level != 1):
        parser.error("Steam achievements require the main campaign starting at room 1.")
    if args.attempts < 1 or args.search_nodes < 1 or not 0 < args.plan_timeout <= 60 or args.batch_steps < 0 or args.stop_after_level < args.start_level or (args.attach and not args.export) or (not args.attach and not (args.game and args.umt)):
        parser.error("Provide --game and --umt, or an existing test folder and --export. Planning timeout must be 0–60 seconds.")

    args.work.mkdir(parents=True, exist_ok=True)
    if args.learning is None:
        args.learning = args.work / "learning"
    if args.verified:
        args.verified.mkdir(parents=True, exist_ok=True)
    session = Path(tempfile.mkdtemp(prefix="minimalism-", dir=args.work))
    print(f"Run files: {session}", flush=True)
    if args.attach:
        data = json.loads(args.export.read_text(encoding="utf-8-sig"))
        play(args, session, args.attach, data, None, args.resume_build)
        return

    save_name = f"MinimalismPlaytest_{uuid.uuid4().hex[:12]}"
    runtime, data, build = prepare(args, session, save_name)
    folder = Path(os.environ["LOCALAPPDATA"]) / save_name
    with (session / "game.log").open("wb") as game_log:
        game = subprocess.Popen([str(runtime / "Minimalism.exe")], cwd=runtime, stdout=game_log, stderr=subprocess.STDOUT)
        try:
            play(args, session, folder, data, game, build)
        except (Exception, KeyboardInterrupt):
            if game.poll() is None:
                game.terminate()
                game.wait(timeout=5)
            raise


if __name__ == "__main__":
    main()
