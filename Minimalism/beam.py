"""Plan alternate reachable poses toward inferred keys, switches, and exits."""

from copy import copy
from heapq import heappop, heappush, nsmallest
from itertools import count, permutations
from math import ceil, inf
from time import monotonic

import numpy as np

from planner import ACTIONS, State


def _recover(route):
    parts = []
    while route:
        route, batch = route
        parts.append(batch)
    return "".join(reversed(parts))


def _stage(planner, sources, distance, threshold, reached, nodes, width, ticks, deadline):
    frontier, seen, samples = [], {}, {}
    sequence = count()
    phase = planner.dynamic.phase if planner.dynamic else lambda _: 0
    start_tick = min(state.tick for state, _ in sources)

    def offer(state, route):
        key = (
            round(state.x / 4), round(state.y / 4), round(state.hspd / 2), round(state.vspd / 2),
            state.grounded, state.state, state.meet, state.wall_jumps, state.jump_held,
            state.invert_gravity, state.gravity_remaining // 12, state.keys, phase(state),
        )
        if state.tick >= seen.get(key, inf):
            return
        seen[key] = state.tick
        cost = state.tick - start_tick + 12 * distance(state)
        heappush(frontier, (cost, next(sequence), state, route))

    for state, controls in sources:
        offer(state, (None, controls))
    for index in range(nodes):
        if not frontier or (index % 128 == 0 and monotonic() >= deadline):
            break
        _, _, state, route = heappop(frontier)
        current_distance = distance(state)
        if reached(state) and planner._can_continue(state, 18):
            return [(state, _recover(route))], True
        if current_distance <= threshold and state.tick - start_tick >= ticks and planner._can_continue(state, 18):
            key = (
                round(state.x / 25), round(state.y / 25), round(state.vspd / 7), round(state.hspd / 4),
                state.grounded, state.invert_gravity, phase(state) // 4,
            )
            if key not in samples:
                samples[key] = state, _recover(route)
            if len(samples) >= width:
                return list(samples.values()), False
        for action in ACTIONS:
            future = state
            for steps in range(1, ticks + 1):
                future = planner.step(future, action)
                if future is None:
                    break
                if reached(future) and planner._can_continue(future, 18):
                    return [(future, _recover((route, str(action) * steps)))], True
                if steps == ticks or (steps == ticks // 2 and current_distance <= threshold + 20):
                    offer(future, (route, str(action) * steps))
    return list(samples.values()), False


def _clearance_planner(planner, tick, deadline):
    """Use a second geometric distance map for nearly permanent moving obstacles."""
    if not planner.dynamic:
        return None
    occupied = np.zeros(planner.grid.shape, dtype=np.uint8)
    height, width = occupied.shape
    scale = planner.GRID
    for offset in range(0, 240, 4):
        if monotonic() >= deadline:
            return None
        frame = np.zeros_like(occupied, dtype=np.bool_)
        hazards, walls = planner.dynamic._forecast(tick + offset)
        for left, top, right, bottom in (*hazards, *walls):
            x1, y1 = max(0, ceil(left / scale)), max(0, ceil(top / scale))
            x2, y2 = min(width, int(right // scale) + 1), min(height, int(bottom // scale) + 1)
            if x2 > x1 and y2 > y1:
                frame[y1:y2, x1:x2] = True
        occupied += frame
    additional_blocks = (occupied >= 54) & ~planner.grid
    if not additional_blocks.any():
        return None
    clearance = copy(planner)
    clearance.grid = planner.grid | additional_blocks
    clearance.distance_maps = {}
    return clearance


def _progress(planner, start, distance, reached, nodes, width, deadline):
    sources = [(start, "")]
    best = distance(start)
    for _ in range(100):
        if monotonic() >= deadline:
            break
        gap = min(38, max(10, best // 6))
        for ticks, target in ((8, best - gap), (5, best - gap // 2), (4, best - 2)):
            candidates, done = _stage(planner, sources, distance, target, reached, nodes, width, ticks, deadline)
            if done:
                return candidates[0]
            if candidates:
                sources = candidates
                best = min(distance(state) for state, _ in sources)
                break
        else:
            break
    return None


def _with_gravity_access(planner, collectibles, switches, door, center, score):
    """Prioritize an inversion when the normal-gravity support cannot reach a pickup."""
    if not switches:
        return []
    height, width = planner.grid.shape
    supported = np.frombuffer(planner._support_grid(), dtype=np.uint8)
    supported = supported.reshape(height + 2, width + 2)[1:-1, 1:-1]
    normal, suspended = [], []
    for objective in collectibles:
        _, rect, _ = objective
        x1, y1 = max(0, ceil(rect.left / planner.GRID)), max(0, ceil(rect.top / planner.GRID))
        x2, y2 = min(width, rect.right // planner.GRID + 1), min(height, rect.bottom // planner.GRID + 1)
        area = np.s_[y1:y2, x1:x2]
        space = (supported[area] != 0) & ~planner.grid[area]
        (normal if space.any() else suspended).append(objective)
    if not suspended:
        return []

    def nearest(items, origin):
        result = []
        while items:
            next_item = min(items, key=lambda item: sum(abs(a - b) for a, b in zip(origin, center(item[1]))))
            items.remove(next_item)
            result.append(next_item)
            origin = center(next_item[1])
        return tuple(result)

    orders = []
    for switch in switches:
        for first in normal or [None]:
            if first is None:
                prefix = ()
            else:
                prefix = (first,) + nearest([item for item in normal if item != first], center(first[1]))
            for split in dict.fromkeys((len(prefix), max(0, len(prefix) - 1), 0)):
                remaining = list(prefix[split:]) + suspended
                follow = nearest(remaining, center(switch[1]))
                orders.append(prefix[:split] + (switch,) + follow + (door,))
    return nsmallest(8, dict.fromkeys(orders), key=score)


def _objectives(planner, initial, deadline=None):
    collectibles = getattr(planner, "collectibles", ())

    def kind(index):
        if index < len(collectibles) and collectibles[index]["name"] != "obj_key":
            return "symbol"
        return "key"

    keys = [
        (f"{kind(index)} {index + 1}", goal, lambda state, index=index: bool(state.keys & (1 << index)))
        for index, goal in enumerate(planner.keys)
        if not initial.keys & (1 << index)
    ]
    door = ("door", planner.goal, lambda state: state.finished)
    switches = [
        ("gravity", goal.inset(-8, -16), lambda state: state.invert_gravity == -1)
        for goal, _ in planner.gravity_buttons
        if initial.invert_gravity == 1
    ]

    def center(rectangle):
        return (rectangle.left + rectangle.right) / 2, (rectangle.top + rectangle.bottom) / 2

    def spatial_score(order):
        x, y = initial.x, initial.y
        total = 0
        for _, rectangle, _ in order:
            next_x, next_y = center(rectangle)
            total += abs(next_x - x) + abs(next_y - y)
            x, y = next_x, next_y
        return total

    def geodesic_score(order):
        state, total = initial, 0
        for _, goal, _ in order:
            distance = planner._distance_estimate(goal) if deadline is None else planner._distance_estimate(goal, deadline=deadline)
            if distance is None:
                return spatial_score(order)
            total += distance(state)
            state = State(*center(goal))
        return total

    chase = getattr(planner.dynamic, "chase", None)
    if chase:
        forward = sorted(keys, key=lambda objective: center(objective[1])[0], reverse=chase[1] < 0)
        return [tuple(forward) + (door,)]

    exhaustive = len(keys) <= 5
    if exhaustive:
        orders = list(permutations(keys))
    else:
        # Start from several nearby items, then greedily extend each route.
        points = [center(goal) for _, goal, _ in keys]

        def nearest_to(x, y, choices):
            return min(choices, key=lambda i: (abs(points[i][0] - x) + abs(points[i][1] - y), i))

        starts = nsmallest(8, range(len(keys)), key=lambda i: abs(points[i][0] - initial.x) + abs(points[i][1] - initial.y))
        orders = []
        for first in starts:
            order, remaining = [keys[first]], set(range(len(keys))) - {first}
            current = first
            while remaining:
                current = nearest_to(*points[current], remaining)
                remaining.remove(current)
                order.append(keys[current])
            orders.append(tuple(order))

    extra_count = len(orders) * len(switches) * (len(keys) + 1)
    if exhaustive and extra_count <= 128:
        all_orders = []
        for order in orders:
            all_orders.append(order + (door,))
            for switch in switches:
                all_orders.extend(order[:i] + (switch,) + order[i:] + (door,) for i in range(len(order) + 1))
        return sorted(all_orders, key=geodesic_score)

    all_orders = [order + (door,) for order in orders]
    nearby_switches = nsmallest(3, switches, key=lambda switch: spatial_score((switch, door)))
    alternatives = (
        order[:i] + (switch,) + order[i:] + (door,)
        for order in orders
        for switch in nearby_switches
        for i in range(len(order) + 1)
    )
    all_orders.extend(nsmallest(128 if exhaustive else 32, alternatives, key=spatial_score))
    ranked = sorted(all_orders, key=geodesic_score if exhaustive else spatial_score)
    if not exhaustive and nearby_switches:
        recommended = _with_gravity_access(planner, keys, nearby_switches, door, center, spatial_score)
        return list(dict.fromkeys(recommended + ranked))[:40]
    return ranked


def plan_beam(planner, state=None, *, nodes=6000, width=12, seconds=90, trace=None):
    """Return native frame actions, or None if the search runs out of time or options."""
    if seconds <= 0 or nodes < 1 or width < 1:
        return None
    deadline = monotonic() + seconds
    initial = planner.start if state is None else state
    if isinstance(initial, dict):
        initial = State.from_telemetry(initial)
    orders = _objectives(planner, initial, deadline)
    clearance = _clearance_planner(planner, initial.tick, deadline)
    prefixes = {}
    for goals in orders:
        if monotonic() >= deadline:
            break
        current, controls, prefix = initial, "", ()
        if trace:
            trace(f"Trying {', '.join(name for name, _, _ in goals)}.")
        for name, rectangle, reached in goals:
            prefix += ((name, rectangle),)
            if prefix not in prefixes:
                variants = ((clearance, False), (planner, True), (planner, False)) if clearance else ((planner, False), (planner, True))
                for model, supported in variants:
                    distance = model._distance_estimate(rectangle, supported, deadline=deadline)
                    if distance is None or (model is not planner and distance(current) >= 10000):
                        continue
                    result = _progress(planner, current, distance, reached, nodes, width, deadline)
                    if result is not None:
                        break
                prefixes[prefix] = result
            result = prefixes[prefix]
            if result is None:
                break
            current, presses = result
            controls += presses
        else:
            return [int(action) for action in controls]
    return None


def _chase_stage(planner, sources, goal, reached, direction, width, nodes, deadline):
    distance = planner._distance_estimate(goal, deadline=deadline)
    if distance is None:
        return []
    goal_edge = goal.right if direction > 0 else -goal.left
    frontier, seen, arrived = [], {}, {}
    sequence = count()

    def offer(state, route):
        if direction * state.x > goal_edge + 145 and not reached(state):
            return
        key = (
            round(state.x / 3), round(state.y / 3), round(state.hspd / 2), round(state.vspd / 2),
            state.state, state.jumps, state.wall_jumps, state.jump_held, state.keys,
        )
        if seen.get(key, inf) <= state.tick:
            return
        seen[key] = state.tick
        heappush(frontier, (state.tick + 5 * distance(state), next(sequence), state, route))

    def collect(state, route):
        key = (
            round(state.x / 9), round(state.y / 8), round(state.vspd / 4), round(state.hspd / 4),
            state.jumps, state.wall_jumps, state.grounded, state.jump_held,
        )
        if key not in arrived and planner._can_continue(state, 19):
            arrived[key] = state, _recover(route)
        return len(arrived) >= width

    for state, controls in sources:
        offer(state, (None, controls))
    for index in range(nodes):
        if not frontier or (index % 128 == 0 and monotonic() >= deadline):
            break
        _, _, state, route = heappop(frontier)
        if reached(state) and collect(state, route):
            break
        if direction * state.x > goal_edge + 200:
            continue
        for action in ACTIONS:
            future = state
            for steps in range(1, 9):
                future = planner.step(future, action)
                if future is None:
                    break
                branch = route, str(action) * steps
                if reached(future) and collect(future, branch):
                    return list(arrived.values())
                if steps in (3, 5, 8):
                    offer(future, branch)
    return list(arrived.values())


def plan_chase(planner, state=None, *, nodes=16000, width=65, seconds=90, trace=None):
    """Preserve alternate pickup states through an ordered moving-wall chase."""
    if not planner.dynamic or not planner.dynamic.chase or seconds <= 0 or nodes < 1 or width < 1:
        return None
    deadline = monotonic() + seconds
    initial = planner.start if state is None else state
    if isinstance(initial, dict):
        initial = State.from_telemetry(initial)
    direction = 1 if planner.dynamic.chase[1] >= 0 else -1
    goals = _objectives(planner, initial, deadline)[0]
    candidates = [(initial, "")]
    for name, goal, reached in goals:
        stage_width = 1 if name == "door" else width
        candidates = _chase_stage(planner, candidates, goal, reached, direction, stage_width, nodes, deadline)
        if not candidates:
            return None
        if trace:
            earliest = min(state.tick for state, _ in candidates)
            trace(f"Reached {name} at step {earliest} with {len(candidates)} usable poses.")
    _, controls = min(candidates, key=lambda candidate: candidate[0].tick)
    return [int(action) for action in controls]
