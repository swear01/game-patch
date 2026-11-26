"""Find a temporary shelter when an arrow blocks a planned passage."""

from time import monotonic

import numpy as np

from planner import Rectangle, expired, nearest_pixel


def _route_poses(planner, initial, actions, deadline):
    world = planner.dynamic
    arrows = world.arrows
    world.arrows = []
    world._forecast.cache_clear()
    try:
        poses = [initial]
        for action in actions:
            if expired(deadline):
                break
            state = planner.step(poses[-1], action)
            if state is None or state.finished:
                break
            poses.append(state)
        return poses
    finally:
        world.arrows = arrows
        world._forecast.cache_clear()


def _shelters(planner, state, lane, projectile):
    direction = 1 if projectile[4] > 0 else -1
    above, below = projectile[3] - 4, projectile[3] + 84
    limit_left, limit_right = max(1, int(state.x) - 610), min(planner.width, int(state.x) + 611)
    x_slice = slice(limit_left, limit_right)
    for y, low, high in ((int(below) + 7, lane, int(below) + 8),
                         (int(above) - 7, int(above) - 7, lane + 1)):
        if not 0 <= low < high <= planner.height:
            continue
        passage = ~(planner._solid[low:high, x_slice] | planner._lethal[low:high, x_slice]).any(axis=0)
        starts = np.flatnonzero(np.diff(np.pad(passage, 1)))
        for left, right in zip(starts[::2], starts[1::2]):
            if right - left < 4:
                continue
            left, right = limit_left + int(left), limit_left + int(right) - 1
            x = min(right - 1, max(left + 1, nearest_pixel(state.x)))
            floor = np.flatnonzero(planner._solid[y:min(y + 140, planner.height), x])
            if y > lane and (not floor.size or int(floor[0]) < 3):
                continue
            lower = y + int(floor[0]) - 1 if y > lane else y
            refuge = Rectangle(left + 1, y if y > lane else max(1, y - 44), right - 1, lower)
            yield abs(x - state.x), -direction * x, refuge


def detour_for_arrows(planner, initial, actions, danger_tick, deadline=None, max_nodes=6500):
    """Return a route suffix that waits out an arrow and rejoins the original passage."""
    world = planner.dynamic
    if not world or not world.arrows or expired(deadline):
        return None
    reference = _route_poses(planner, initial, actions[:360], deadline)
    index = danger_tick - initial.tick
    if not 0 < index < len(reference):
        return None
    danger = reference[index]
    involved = []
    for projectile in world.arrows:
        fired, end, x, y, velocity = projectile
        if (fired <= danger_tick < end and y - 4 <= danger.y <= y + 84
                and abs(x + (danger_tick - fired) * velocity - danger.x) <= 70):
            involved.append(projectile)
    if not involved:
        return None
    projectile = involved[0]
    fired, end, x, _, velocity = projectile
    lane = nearest_pixel(danger.y)
    heading = 1 if danger.hspd > 0 else -1

    def search(state, target, attained, stride, limit):
        return planner.search(state, target, attained, max_nodes, stride, 10, 3, deadline=limit)

    best = None
    for _, _, refuge in sorted(_shelters(planner, initial, lane, projectile), key=lambda item: item[:2]):
        if expired(deadline):
            break
        goal_x = (refuge.left + refuge.right) / 2
        cross_time = fired + (goal_x - x) / velocity
        if cross_time < initial.tick - 12 or abs(goal_x - initial.x) / 8 + 10 > cross_time - initial.tick + 8:
            continue
        after_pass = min(end, int(cross_time + 13))
        local = monotonic() + 0.65
        if deadline is not None:
            local = min(local, deadline)
        reached = lambda pose: refuge.contains(pose.x, pose.y) and planner._can_continue(pose, 4)
        planned = search(initial, refuge, reached, 5, local)
        if not planned:
            planned = search(initial, refuge, reached, 3, local)
        if not planned:
            continue
        inputs, pose = planned
        while pose.tick < after_pass and not expired(deadline):
            pose = planner.step(pose, 0)
            if pose is None:
                break
            inputs.append(0)
        if pose is None or expired(deadline):
            continue

        for distance in (36, 70, 110):
            candidates = [candidate for candidate in reference[12:]
                          if distance <= (candidate.x - goal_x) * heading <= distance + 65
                          and abs(candidate.y - lane) <= 120 and candidate.hspd * heading >= 5]
            anchor = min(candidates, key=lambda item: (not item.grounded, abs(item.vspd), item.tick), default=None)
            if anchor is None or expired(deadline):
                continue
            offset = anchor.tick - initial.tick
            px, py = nearest_pixel(anchor.x), nearest_pixel(anchor.y)
            reunion = Rectangle(px - 3, py - 2, px + 3, py + 2)

            def rejoined(future):
                return (reunion.contains(future.x, future.y) and future.grounded == anchor.grounded
                        and future.invert_gravity == anchor.invert_gravity
                        and abs(future.hspd - anchor.hspd) <= 0.7 and abs(future.vspd - anchor.vspd) <= 0.7)

            limit = monotonic() + 0.6
            if deadline is not None:
                limit = min(limit, deadline)
            result = search(pose, reunion, rejoined, 4, limit)
            if result is None:
                continue
            segment, state = result
            remaining = actions[offset:]
            completed = 0
            for action in remaining:
                if expired(deadline):
                    break
                state = planner.step(state, action)
                if state is None:
                    break
                completed += 1
                if state.finished:
                    return inputs + segment + list(remaining[:completed])
            if completed >= 48 and (best is None or completed > best[0]):
                best = completed, inputs + segment + list(remaining[:completed])
    return None if best is None else best[1]
