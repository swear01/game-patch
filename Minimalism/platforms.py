"""Search the inferred walkable platforms while preserving the game's movement rules."""

from collections import defaultdict
from dataclasses import dataclass
from heapq import heappop, heappush
from itertools import count
import math
from time import monotonic

import numpy as np

from planner import Rectangle, expired


@dataclass(frozen=True, slots=True)
class Platform:
    left: int
    right: int
    y: int
    depth: int
    wall: bool = False

    @property
    def x(self):
        return (self.left + self.right) / 2

    @property
    def goal(self):
        if self.wall:
            return Rectangle(self.left, self.y - 14, self.right, self.y + 14)
        return Rectangle(self.left, self.y - 12, self.right, self.y + 1)

    def can_land(self, state):
        if not self.goal.contains(state.x, state.y):
            return False
        return state.vspd <= 5 if self.wall else state.vspd >= 0


def find_platforms(planner):
    supported = planner._solid[1:] & ~planner._solid[:-1] & ~planner._lethal[:-1]
    edges = np.diff(np.pad(supported, ((0, 0), (1, 1))), axis=1)
    py, px = np.nonzero(edges)
    result = []
    for left_i in range(0, len(px), 2):
        left, right, y = int(px[left_i]), int(px[left_i + 1]) - 1, int(py[left_i])
        if right - left <= 10:
            continue
        for start in range(left, right, 128):
            end = min(right, start + 156)
            center = (start + end) // 2
            below = planner._solid[y + 1:min(y + 198, planner.height + 1), center]
            end_wall = np.flatnonzero(~below)
            height = int(end_wall[0]) if end_wall.size else len(below)
            result.append(Platform(start + 3, end - 3, y, height))
            if end == right:
                break
    return result


def find_wall_anchors(planner):
    solid, lethal = planner._solid, planner._lethal
    left_of_wall = solid[:, 1:] & ~solid[:, :-1] & ~lethal[:, :-1]
    right_of_wall = solid[:, :-1] & ~solid[:, 1:] & ~lethal[:, 1:]
    result = []
    for adjacency, offset in ((left_of_wall, 0), (right_of_wall, 1)):
        edges = np.diff(np.pad(adjacency.T, ((0, 0), (1, 1))), axis=1)
        px, py = np.nonzero(edges)
        for start in range(0, len(py), 2):
            x, top, bottom = int(px[start]) + offset, int(py[start]), int(py[start + 1]) - 1
            if bottom - top < 95:
                continue
            end = min(bottom - 17, planner.height - 3)
            for y in range(top + 16, end + 1, 122):
                result.append(Platform(max(1, x - 9), min(planner.width - 1, x + 9), y, 175, True))
    return result


def flight_cost(source, target):
    dx = max(0, source.left - target.right, target.left - source.right)
    dy = target.y - source.y
    effective_dy = dy + min(target.depth - 8, 182)
    discriminant = 12.56**2 + 0.96 * effective_dy
    if dy > 1400 or discriminant < 0:
        return None
    air_frames = (12.56 + math.sqrt(discriminant)) / 0.48
    if dx > min(490, 7.8 * air_frames + 24):
        return None
    # Prefer transfers that only need one ordinary jump.
    wall_assist = 20 if dy < -160 or dx > 340 else 0
    return 14 + dx / 7.8 + abs(dy) / 15 + wall_assist


class PlatformRoutes:
    def __init__(self, planner, deadline=None, wall_nodes=False):
        self.planner = planner
        self.platforms = find_platforms(planner)
        if wall_nodes and not expired(deadline):
            self.platforms.extend(find_wall_anchors(planner))
        self.edges = defaultdict(list)
        self.reverse = defaultdict(list)
        for start, source in enumerate(self.platforms):
            if expired(deadline):
                break
            for end, target in enumerate(self.platforms):
                if start == end:
                    continue
                cost = flight_cost(source, target)
                if cost is not None:
                    self.edges[start].append((cost, end))
                    self.reverse[end].append((cost, start))

    def connect(self, goal, deadline=None):
        distance_to_goal = self.planner._distance_estimate(goal, deadline=deadline)
        if distance_to_goal is None:
            return {}, set()
        connected = {index for index, platform in enumerate(self.platforms)
                     if distance_to_goal(platform) < 10000}
        middle = (goal.top + goal.bottom) // 2
        apparent = Platform(goal.left, goal.right, middle, 30)
        distance = {}
        queue = []
        approaches = set()
        for index, platform in enumerate(self.platforms):
            if index not in connected:
                continue
            cost = flight_cost(platform, apparent)
            if cost is None:
                horizontal = max(0, apparent.left - platform.right, platform.left - apparent.right)
                vertical = apparent.y - platform.y
                if horizontal <= 180 and -425 <= vertical <= 1250:
                    cost = 40 + horizontal / 7.8 + abs(vertical) / 5
            if cost is not None:
                approaches.add(index)
                distance[index] = cost
                heappush(queue, (cost, index))
        while queue:
            if expired(deadline):
                return {}, set()
            cost, index = heappop(queue)
            if cost > distance[index]:
                continue
            for step, source in self.reverse[index]:
                if source in connected and cost + step < distance.get(source, math.inf):
                    distance[source] = cost + step
                    heappush(queue, (cost + step, source))
        return distance, approaches

    def cross_gap(self, state, source, target, reached, max_nodes, deadline):
        direction = 1 if target.left > source.right else -1
        gap = (target.left - source.right) if direction == 1 else (source.left - target.right)
        if source.wall or target.wall or abs(source.y - target.y) > 4 or not 145 <= gap <= 460:
            return None
        edge = source.right if direction == 1 else source.left
        left, right = (edge - 25, edge - 4) if direction == 1 else (edge + 4, edge + 25)
        takeoff = Rectangle(left, source.y - 2, right, source.y + 1)

        def on_edge(pose):
            return takeoff.contains(pose.x, pose.y) and pose.hspd * direction >= 5 and pose.jumps > 0

        actual_goal = lambda pose: reached(pose) or target.can_land(pose)
        for stride in (5, 4):
            launch = self.planner.search(state, takeoff, on_edge, min(max_nodes, 2500), stride, 9, 4,
                                         deadline=deadline)
            if launch is None:
                continue
            inputs, takeoff_state = launch
            landed = self.planner.search(takeoff_state, target.goal, actual_goal, max_nodes, stride, 10, 4,
                                          deadline=deadline)
            if landed is not None:
                controls, pose = landed
                return inputs + controls, pose
        return None

    def to(self, initial, goal, reached, max_nodes=2500, trace=None, deadline=None):
        route_distance, approaches = self.connect(goal, deadline)
        if trace:
            trace(f"Target {goal} from ({initial.x:.1f}, {initial.y:.1f}), {initial.tick} frames")
        if not route_distance:
            return None
        clock = count()
        frontier = []
        seen = set()
        start = Platform(int(initial.x), int(initial.x), int(initial.y), 0)
        costs = []
        for index, platform in enumerate(self.platforms):
            cost = flight_cost(start, platform)
            if cost is not None and index in route_distance:
                costs.append((cost, index))
        hit = self.planner.search(initial, goal, reached, min(max_nodes, 1000), deadline=deadline)
        if hit:
            return hit
        for cost, index in costs:
            heappush(frontier, (cost + route_distance[index], next(clock), initial, -1, index, []))
        for _ in range(420):
            if not frontier or expired(deadline):
                break
            _, _, state, origin, target, actions = heappop(frontier)
            signature = (round(state.x / 15), round(state.y / 12), round(state.hspd / 3),
                         round(state.vspd / 4), target, state.keys)
            if signature in seen:
                continue
            seen.add(signature)
            platform = self.platforms[target]
            arrived = lambda s: reached(s) or platform.can_land(s)
            result = None
            for primitive in (5, 8, 3):
                result = self.planner.search(
                    state, platform.goal, arrived, max_nodes, primitive, 8, 5, deadline=deadline,
                )
                if result:
                    break
            if result is None and origin >= 0:
                result = self.cross_gap(state, self.platforms[origin], platform, reached, max_nodes, deadline)
            if not result:
                continue
            segment, pose = result
            if trace:
                trace(f"Platform {target} at ({pose.x:.1f}, {pose.y:.1f}), {pose.tick} frames")
            full = actions + segment
            if reached(pose):
                return full, pose
            if target in approaches:
                result = self.planner.search(pose, goal, reached, max_nodes, 5, 8, 5, deadline=deadline)
                if result:
                    segment, pose = result
                    return full + segment, pose
            for cost, other in self.edges[target]:
                if other not in route_distance:
                    continue
                duration = len(full) + 4 * (cost + route_distance[other])
                heappush(frontier, (duration, next(clock), pose, target, other, full))
        return None


def plan_platforms(planner, state=None, max_nodes=2500, attempt=0, trace=None, deadline=None,
                   wall_nodes=False, ordered=False):
    state = state or planner.start
    if state.invert_gravity != 1 or expired(deadline):
        return None
    routes = PlatformRoutes(planner, deadline, wall_nodes)
    if ordered:
        choices = planner.ranked_orders(state, deadline=deadline)
        if not choices:
            return None
        order = choices[attempt % len(choices)]
    else:
        order = planner.objective_order(state, attempt, deadline)
    controls = []
    for target in (*[target for target in order if target >= 0], -1):
        goal = planner.goal if target == -1 else planner.keys[target]

        def reached(s):
            return s.finished if target == -1 else bool(s.keys & (1 << target)) and planner._can_continue(s, 18)

        result = routes.to(state, goal, reached, max_nodes, trace, deadline)
        if not result:
            return None
        segment, state = result
        controls += segment
    return controls


def plan_portal_exit(planner, state, max_nodes=16000, deadline=None, trace=None):
    """Find a path through a floor opening into the room that contains the exit."""
    if state.keys != planner.all_keys or state.invert_gravity != 1 or expired(deadline):
        return None
    door = planner.goal
    cx, cy = (door.left + door.right) // 2, door.top + min(24, (door.bottom - door.top) // 4)
    blocked = planner._solid | planner._lethal
    if blocked[cy, cx]:
        return None
    blockers = np.flatnonzero(blocked[cy])
    left = max((int(x) + 1 for x in blockers if x < cx), default=1)
    right = min((int(x) - 1 for x in blockers if x > cx), default=planner.width - 1)
    floors = np.flatnonzero(planner._solid[cy:, cx])
    if not floors.size:
        return None
    floor = cy + int(floors[0])
    if floor + 5 >= planner.height or floor - cy > 300:
        return None
    openings = np.flatnonzero(np.diff(np.pad(~blocked[floor + 3, left:right + 1], (1, 1))))
    portals = [(left + int(a), left + int(b) - 1) for a, b in zip(openings[::2], openings[1::2])
               if 45 <= b - a <= 340 and a > 0 and left + b <= right and right - left > (b - a) * 2]
    if not portals:
        return None

    def near(state, goal, allow=4):
        for primitive, weight in ((8, 8), (5, 10), (4, 10), (6, 12))[:allow]:
            local = min(deadline, monotonic() + 2.5) if deadline is not None else monotonic() + 2.5
            result = planner.search(
                state, goal, lambda s: goal.contains(s.x, s.y) and planner._can_continue(s),
                max_nodes, primitive, weight, 4, deadline=local,
            )
            if result:
                return result
            if expired(deadline):
                break
        return None

    for lo, hi in sorted(portals, key=lambda span: abs((span[0] + span[1]) / 2 - state.x)):
        if expired(deadline):
            break
        middle = (lo + hi) // 2
        outer = int(np.clip(state.x, max(1, lo - 160), min(planner.width - 1, hi + 160)))
        if lo <= state.x <= hi:
            entries = [int(state.y)]
        else:
            first = max(floor + 100, int(state.y) - 220)
            last = planner.height - 10
            lateral = ~np.any(blocked[first:last + 1, min(outer, middle):max(outer, middle) + 1], axis=1)
            spans = np.flatnonzero(np.diff(np.pad(lateral, (1, 1))))
            openings = [(int(b) - int(a), first + (int(a) + int(b)) // 2)
                        for a, b in zip(spans[::2], spans[1::2]) if b - a >= 15]
            entries = [y for width, y in sorted(openings, key=lambda entry: (entry[0] < 40, abs(entry[1] - state.y)))]
        if trace:
            trace(f"Portal x={lo}–{hi}, floor y={floor}, entry heights={entries[:8]}.")
        for entry in entries[:8]:
            if expired(deadline):
                return None
            anchor = Rectangle(lo + 4, max(floor + 8, entry - 14), hi - 4, entry + 14)
            first_leg = near(state, anchor, 2)
            if not first_leg:
                continue
            controls, current = first_leg
            if trace:
                trace(f"Entered shaft at {current.x:.1f}, {current.y:.1f}.")
            while current.y > floor + 24 and not expired(deadline):
                y = max(floor + 15, int(current.y) - 140)
                rung = Rectangle(lo + 2, y - 22, hi - 2, y + 8)
                result = near(current, rung)
                if not result or not result[0]:
                    break
                batch, current = result
                controls += batch
            if current.y > floor + 24 or expired(deadline):
                continue
            lip = Rectangle(lo + 2, max(1, floor - 106), hi - 2, floor - 55)
            result = near(current, lip)
            if not result:
                continue
            batch, current = result
            controls += batch
            finish = planner.search(current, door, lambda s: s.finished,
                                    max_nodes, 6, 10, 4, deadline=deadline)
            if finish:
                return controls + finish[0]
    return None


def approach_collectible_from_wall(planner, state, index, max_nodes=10000, deadline=None, trace=None):
    """Approach a high pickup using a wall that can be climbed from below."""
    goal = planner.keys[index]
    if expired(deadline):
        return None
    x, y = (goal.left + goal.right) // 2, (goal.top + goal.bottom) // 2
    solid, lethal = planner._solid, planner._lethal
    options = []
    for direction in (-1, 1):
        for offset in range(50, 425):
            wall_x, inner_x = x + direction * offset, x + direction * (offset - 1)
            if not (1 <= wall_x < planner.width):
                break
            if not solid[y, wall_x] or solid[y, inner_x] or lethal[y, inner_x]:
                continue
            safe = solid[y:, wall_x] & ~solid[y:, inner_x] & ~lethal[y:, inner_x]
            breaks = np.flatnonzero(~safe)
            depth = int(breaks[0]) if breaks.size else len(safe)
            if depth >= 220:
                options.append((offset + abs(y + depth - state.y) / 8, direction, wall_x, y + depth))
                break
    for _, direction, wall_x, bottom in sorted(options):
        across_wall = (state.x - wall_x) * direction > 0
        if state.y <= goal.bottom + 90 and not across_wall:
            continue
        x_left, x_right = (wall_x - 44, wall_x - 1) if direction == 1 else (wall_x + 1, wall_x + 44)
        current, controls = state, []
        first = bottom - 15 if across_wall else min(bottom - 15, int(current.y) - 80)
        if trace:
            trace(f"Climbing wall x={wall_x} from y={first} toward pickup {index}.")
        for threshold in range(first, y - 30, -132):
            if expired(deadline):
                return None
            rung = Rectangle(x_left, threshold - 35, x_right, threshold + 8)

            def near(pose):
                return rung.contains(pose.x, pose.y) and planner._can_continue(pose, 12)

            result = None
            for primitive, weight in ((5, 10), (8, 8), (4, 10)):
                subdeadline = min(deadline, monotonic() + 1.25) if deadline is not None else monotonic() + 1.25
                result = planner.search(current, rung, near, max_nodes, primitive, weight, 4, deadline=subdeadline)
                if result:
                    break
            if result is None:
                break
            leg, current = result
            controls += leg
        else:
            def gets_symbol(pose):
                return bool(pose.keys & (1 << index)) and planner._can_continue(pose, 12)

            found = planner.search(current, goal, gets_symbol, max_nodes, 5, 10, 4, deadline=deadline)
            if found:
                final, end = found
                return controls + final, end
    return None


def stabilize_wall_pickup(planner, initial, index, approach, max_nodes=14000, deadline=None):
    """Keep a descending pickup on its adjacent wall so the player can climb back out."""
    goal = planner.keys[index]
    solid = planner._solid
    center_y = (goal.top + goal.bottom) // 2
    left, right = max(1, goal.left), min(planner.width - 1, goal.right)
    if left >= right or not 0 < center_y < planner.height:
        return None
    edges = np.diff(solid[center_y, left:right + 1])
    walls = []
    for edge in np.flatnonzero(edges):
        x = left + int(edge)
        direction = -1 if solid[center_y, x] else 1
        wall = x + int(direction > 0)
        face = wall - direction
        safe_wall = solid[:center_y + 1, wall] & ~solid[:center_y + 1, face]
        interruptions = np.flatnonzero(~safe_wall)
        top = int(interruptions[-1]) + 1 if interruptions.size else 0
        if center_y - top > 135:
            walls.append((wall, direction, top))
    if not walls:
        return None

    prefix = []
    state = initial
    for action in approach:
        if expired(deadline):
            return None
        state = planner.step(state, action)
        if state is None or state.keys & (1 << index):
            return None
        prefix.append(action)
        if not goal.top - 150 <= state.y <= goal.top - 48:
            continue
        for wall, direction, top in walls:
            distance = (wall - state.x) * direction
            if not 0 < distance < right - left - 15 or state.hspd * direction < 2 or state.vspd <= 0:
                continue
            result = _climb_after_wall_pickup(planner, state, index, wall, direction, top,
                                             max_nodes, deadline)
            if result:
                inputs, pose = result
                return prefix + inputs, pose
    return None


def _climb_after_wall_pickup(planner, state, index, wall, direction, top, max_nodes, deadline):
    def alongside(low, high, width):
        left, right = sorted((wall - direction * width, wall - direction))
        return Rectangle(max(1, left), low, min(planner.width - 1, right), high)

    goal = planner.keys[index]
    contact = alongside(goal.top, goal.bottom - 11, 12)

    def got_item(pose):
        return (bool(pose.keys & (1 << index)) and contact.contains(pose.x, pose.y)
                and pose.hspd * direction >= -1 and pose.vspd < 21 and planner._can_continue(pose, 10))

    result = planner.search(state, contact, got_item, max_nodes, 5, 10, 4, deadline=deadline)
    if not result:
        return None
    inputs, pose = result
    first = round(pose.y) - 72
    for y in range(first, top - 24, -99):
        if expired(deadline):
            return None
        rung = alongside(y - 34, y + 25, 18)

        def climbs(next_pose):
            return (rung.contains(next_pose.x, next_pose.y)
                    and (next_pose.wall_jump_can or next_pose.vspd < 0)
                    and planner._can_continue(next_pose, 8))

        estimate = planner._distance_estimate(rung, "standing", deadline)
        if estimate is None:
            return None
        for stride in (4, 5, 8, 3):
            local = monotonic() + 1.2
            if deadline is not None:
                local = min(local, deadline)
            result = planner.search(pose, rung, climbs, max_nodes, stride, 10, 4,
                                    estimate=estimate, deadline=local)
            if result:
                break
        if not result:
            return None
        segment, pose = result
        inputs += segment
    return inputs, pose


def approach_inverted_collectible(planner, state, index, max_nodes=14000, deadline=None, trace=None):
    """Use an inversion to travel around a divider and under a suspended item."""
    if not planner.gravity_buttons or expired(deadline):
        return None
    goal = planner.keys[index]
    x, y = (goal.left + goal.right) // 2, (goal.top + goal.bottom) // 2
    solid = planner._solid
    directions = []
    for direction in (-1, 1):
        hits = [m for m in range(45, 430)
                if 0 < x + direction * m < planner.width and solid[y, x + direction * m]]
        if not hits:
            continue
        inner = x + direction * hits[0]
        outer = inner
        while 0 < outer + direction < planner.width and solid[y, outer + direction]:
            outer += direction
        above = np.flatnonzero(~solid[:y + 1, inner])
        below = np.flatnonzero(~solid[y:, inner])
        if not above.size or not below.size:
            continue
        top, bottom = int(above[-1]) + 1, y + int(below[0]) - 1
        if bottom - top >= 400:
            directions.append((abs(inner - x), direction, inner, outer, top, bottom))

    def find_leg(current, box, completed, modes=("ceiling", False), motion=((5, 10), (8, 8), (4, 12))):
        for mode in modes:
            estimate = planner._distance_estimate(box, mode, deadline)
            if estimate is None:
                return None
            for primitive, weight in motion:
                local = min(deadline, monotonic() + 1.6) if deadline is not None else monotonic() + 1.6
                result = planner.search(current, box, completed, max_nodes, primitive, weight, 4,
                                        estimate=estimate, deadline=local)
                if result:
                    return result
                if expired(deadline):
                    return None
        return None

    for _, direction, inner, outer, top, bottom in sorted(directions):
        controls, current = [], state
        if current.invert_gravity == 1:
            if (current.x - outer) * direction > 0 and current.y > top - 6:
                edge = outer + direction
                extreme = min(planner.width - 1, outer + 320) if direction == 1 else max(1, outer - 320)
                left, right = sorted((edge, extreme))
                first = int(current.y) - 110
                last = top - 30
                for row in (*range(first, last, -128), last):
                    if expired(deadline):
                        return None
                    rung = Rectangle(left, max(1, row - 25), right, row + 8)
                    ascent = find_leg(current, rung, lambda pose: rung.contains(pose.x, pose.y)
                                      and planner._can_continue(pose), modes=(True, False))
                    if not ascent:
                        break
                    leg, current = ascent
                    controls += leg
                    if trace:
                        trace(f"Reached normal-gravity ledge at ({current.x:.1f}, {current.y:.1f}).")
                else:
                    near_left, near_right = sorted((inner - direction * 115, inner - direction * 9))
                    over = Rectangle(near_left, max(1, top - 200), near_right, top - 4)
                    crossed = find_leg(current, over, lambda pose: over.contains(pose.x, pose.y)
                                       and planner._can_continue(pose), modes=(False, True))
                    if crossed:
                        leg, current = crossed
                        controls += leg
            activated = None
            switches = sorted(planner.gravity_buttons, key=lambda item: (
                abs((item[0].left + item[0].right) / 2 - current.x) + abs((item[0].top + item[0].bottom) / 2 - current.y)))
            for rect, _ in switches:
                activated = find_leg(current, rect.inset(-10, -16), lambda pose: pose.invert_gravity < 0,
                                     modes=(False, True))
                if activated:
                    break
            if not activated:
                continue
            leg, current = activated
            controls += leg
            if trace:
                trace(f"Inverted at tick {current.tick}, ({current.x:.1f}, {current.y:.1f}).")
        if current.gravity_remaining < 180:
            continue
        crossing_low, crossing_high = sorted((outer + direction * 15, outer + direction * 145))
        entry = Rectangle(max(1, crossing_low), max(1, top - 245), min(planner.width - 1, crossing_high), top - 5)

        def target(current, box):
            return find_leg(current, box, lambda pose: box.contains(pose.x, pose.y)
                            and pose.invert_gravity < 0 and planner._can_continue(pose))

        result = target(current, entry)
        if not result:
            continue
        steps, current = result
        controls += steps
        if trace:
            trace(f"Crossed over divider at ({current.x:.1f}, {current.y:.1f}).")
        edge = outer + direction * 1
        opposite = min(planner.width - 1, outer + 320) if direction == 1 else max(1, outer - 320)
        left, right = sorted((edge, opposite))
        first = top + 105
        last = bottom - 85
        for row in (*range(first, last, 132), last):
            if expired(deadline):
                return None
            rung = Rectangle(left, row - 22, right, row + 12)
            result = target(current, rung)
            if not result:
                break
            steps, current = result
            controls += steps
            if trace:
                trace(f"Moved down to ({current.x:.1f}, {current.y:.1f}) at tick {current.tick}.")
        else:
            return_lo, return_hi = sorted((inner - direction * 115, inner - direction * 5))
            under = Rectangle(max(1, return_lo), bottom + 12,
                              min(planner.width - 1, return_hi), min(planner.height - 1, bottom + 205))
            result = target(current, under)
            if not result:
                continue
            steps, current = result
            controls += steps
            result = find_leg(current, goal, lambda pose: bool(pose.keys & (1 << index))
                              and planner._can_continue(pose))
            if result:
                steps, end = result
                return controls + steps, end
    return None


if __name__ == "__main__":
    import argparse
    from pathlib import Path
    from planner import Planner

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("geometry", type=Path)
    parser.add_argument("level", type=int)
    parser.add_argument("--attempt", type=int, default=0)
    parser.add_argument("--max-nodes", type=int, default=2500)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    planner = Planner.from_export(args.geometry, args.level)
    result = plan_platforms(planner, attempt=args.attempt, max_nodes=args.max_nodes, trace=print)
    if not result:
        raise SystemExit("No platform route")
    args.output.write_text("".join(map(str, result)), encoding="ascii")
