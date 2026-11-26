"""Frame-based hazard forecasts for the single-player Minimalism test."""

from functools import lru_cache
from math import ceil, cos, gcd, radians, sin
from pathlib import Path
from struct import Struct
import base64
import re

import numpy as np

_SPAN = Struct("<hh")


_ASSIGNMENT = re.compile(r"(?:^|(?<=;))\s*(\w+)\s*=\s*(-?\d+(?:\.\d+)?)\s*;", re.M)
_SPIKE_DIRECTIONS = {
    "obj_spike_move_up": (0, -1),
    "obj_spike_move_down": (0, 1),
    "obj_spike_move_left": (-1, 0),
    "obj_spike_move_right": (1, 0),
}
_PISTONS = {"obj_piston2", "obj_piston3"}
_SHOOTERS = {"obj_shooter_left": -8.64, "obj_shooter_right": 8.64}
_SHURIKEN = {"obj_shuriken1", "obj_shuriken2", "obj_shuriken3"}


def _bounds(instance, sprite, extra_rotation=0):
    """Return an inclusive collision rectangle in room coordinates."""
    angle = radians(instance["rotation"] + extra_rotation)
    cosine, sine = cos(angle), sin(angle)
    vertices = []
    for x in (sprite["left"], sprite["right"] + 1):
        for y in (sprite["top"], sprite["bottom"] + 1):
            sx = (x - sprite["originX"]) * instance["scaleX"]
            sy = (y - sprite["originY"]) * instance["scaleY"]
            vertices.append((instance["x"] + cosine * sx + sine * sy,
                             instance["y"] - sine * sx + cosine * sy))
    x_values, y_values = zip(*vertices)
    return (
        round(min(x_values) + 1e-9), round(min(y_values) + 1e-9),
        round(max(x_values) + 1e-9) - 1, round(max(y_values) + 1e-9) - 1,
    )


def _for_player(rectangle):
    left, top, right, bottom = rectangle
    return left - 39, top + 1, right + 40, bottom + 80


def _move(rectangle, dx=0, dy=0):
    left, top, right, bottom = rectangle
    return left + dx, top + dy, right + dx, bottom + dy


def _contains(rectangle, x, y):
    left, top, right, bottom = rectangle
    return left <= x <= right and top <= y <= bottom


def _near(rectangle, x, y, margin):
    left, top, right, bottom = rectangle
    return left - margin <= x <= right + margin and top - margin <= y <= bottom + margin


def _overlaps(first, second):
    return (first[0] <= second[2] and second[0] <= first[2] and
            first[1] <= second[3] and second[1] <= first[3])


def _pulse(tick, speed_go, speed_back, time_wait):
    outbound = ceil(35 / speed_go)
    extent = speed_go * outbound
    inbound = ceil(extent / speed_back)
    age = tick % (outbound + inbound + time_wait)
    return max(0, min(age * speed_go, extent - (age - outbound) * speed_back))


def _spinner_masks(item, sprite, angular_speed):
    masks = sprite.get("bitmapMasks")
    if not masks:
        return tuple((_for_player(_bounds(item, sprite, tick * angular_speed)), None)
                     for tick in range(360))
    return _bitmap_spinner_frames(
        masks[0], (sprite["height"], sprite["width"]),
        (sprite["originX"], sprite["originY"]), (item["scaleX"], item["scaleY"]),
        (item["x"], item["y"]), item["rotation"], angular_speed,
    )


@lru_cache(maxsize=64)
def _bitmap_spinner_frames(encoded_mask, size, origin, scale, position, rotation, angular_speed):
    """Reuse exact pixel spans when rebuilding a planner for the same moving obstacle."""
    height, width = size
    x, y = position
    raw = base64.b64decode(encoded_mask)
    mask = np.unpackbits(np.frombuffer(raw, dtype=np.uint8)).reshape(height, -1)
    wy, wx = np.nonzero(mask[:, :width])
    wx = (wx - origin[0]) * scale[0]
    wy = (wy - origin[1]) * scale[1]
    player_width = 80
    tolerance = 1
    reach = player_width - 1 + 2 * tolerance
    frames = []
    period = 360
    if float(angular_speed).is_integer():
        period //= gcd(360, int(angular_speed))
    for tick in range(period):
        angle = radians(rotation + tick * angular_speed)
        cosine, sine = cos(angle), sin(angle)
        rx = np.rint(x + cosine * wx + sine * wy).astype(np.int32)
        ry = np.rint(y - sine * wx + cosine * wy).astype(np.int32)
        top, bottom = int(ry.min()), int(ry.max())
        left, right = int(rx.min()), int(rx.max())
        rows = bottom - top + 1
        x_min = np.full(rows, right + 1000, dtype=np.int32)
        x_max = np.full(rows, left - 1000, dtype=np.int32)
        np.minimum.at(x_min, ry - top, rx)
        np.maximum.at(x_max, ry - top, rx)
        low = np.lib.stride_tricks.sliding_window_view(
            np.pad(x_min, (reach, reach), constant_values=right + 1000),
            player_width + 2 * tolerance,
        ).min(axis=1) - 39 - tolerance
        high = np.lib.stride_tricks.sliding_window_view(
            np.pad(x_max, (reach, reach), constant_values=left - 1000),
            player_width + 2 * tolerance,
        ).max(axis=1) + 40 + tolerance
        top += 1 - tolerance
        frame = (int(low.min()), top, int(high.max()), top + len(low) - 1)
        rows = np.column_stack((low, high)).astype("<i2").tobytes()
        frames.append((frame, rows))
    return tuple(frames)


def _spinner_hits(frame, x, y):
    envelope, rows = frame
    if not _contains(envelope, x, y):
        return False
    if rows is None:
        return True
    left, right = _SPAN.unpack_from(rows, (y - envelope[1]) * _SPAN.size)
    return left <= x <= right


class DynamicWorld:
    """Precompute deterministic motion and add arrow observations when available."""

    def __init__(self, planner, export, code_dir=None):
        self.code_dir = Path(code_dir) if code_dir else None
        self.objects = export["objects"]
        self.sprites = export["sprites"]
        self.height = planner.room["height"]
        self.width = planner.room["width"]
        self.pulses = []
        self.spinners = []
        self.pistons = []
        self.piston_frames = [()]
        self.fall = None
        self.fall_item = None
        self.fall_observation = None
        self.fall_trigger = None
        self.chase = None
        self.chase_stop = self.width
        self.shooters = {}
        self.arrows = []
        self.static_walls = []
        self.static_spikes = []
        self.creation = {}
        self._forecast = lru_cache(maxsize=4096)(self._frame)

        for item in planner.room["instances"]:
            name = item["name"]
            if name in {"obj_wall_general", "obj_crash_wall", "obj_button_grav"}:
                self.static_walls.append(self._bounds(item))
            elif name in {"obj_spike", "obj_spike_min"}:
                self.static_spikes.append(self._bounds(item))

        fall_settings = None
        for item in planner.room["instances"]:
            name = item["name"]
            if name in _PISTONS:
                self._add_piston(item)
            elif name in _SPIKE_DIRECTIONS:
                settings = self._settings(item)
                self.pulses.append((
                    _for_player(self._bounds(item)),
                    *_SPIKE_DIRECTIONS[name],
                    settings.get("speed_go", 2),
                    settings.get("speed_back", 0.25),
                    int(settings.get("time_wait", 20)),
                ))
            elif name in _SHURIKEN:
                self._add_spinner(item)
            elif name == "obj_activate_spike_fall":
                self.fall_trigger = _for_player(self._bounds(item))
            elif name == "obj_spike_fall":
                self.fall_item = item
                fall_settings = self._bounds(item), self._settings(item).get("spd", 7)
            elif name == "obj_spike_wall1":
                self.chase = _for_player(self._bounds(item)), self._settings(item).get("spd", 6.5)
            elif name == "obj_stop_spike_wall":
                self.chase_stop = self._bounds(item)[0]
            elif name in _SHOOTERS:
                self.shooters[item["id"]] = item["x"], item["y"], _SHOOTERS[name]
        if fall_settings:
            self.fall = self._fall_frames(*fall_settings)
        if self.chase:
            player_rect, speed = self.chase
            unpadded_right = player_rect[2] - 40
            self.chase = (player_rect, speed, max(0, ceil((self.chase_stop - unpadded_right) / speed)))
        self.active = bool(self.pistons or self.pulses or self.spinners or self.fall or self.chase or self.shooters)

    def _bounds(self, item):
        obj = self.objects[item["name"]]
        return _bounds(item, self.sprites[obj["mask"] or obj["sprite"]])

    def _settings(self, item):
        if "settings" in item:
            return item["settings"]
        code = item["code"]
        if not code or self.code_dir is None:
            return {}
        if code not in self.creation:
            source = (self.code_dir / (code + ".gml")).read_text(encoding="utf-8-sig")
            self.creation[code] = {name: float(value) for name, value in _ASSIGNMENT.findall(source)}
        return self.creation[code]

    def gravity_duration(self, item):
        return int(self._settings(item).get("time_gravity", 30))

    def _add_piston(self, item):
        bounds = self._bounds(item)
        settings = self._settings(item)
        speed = settings.get("speed_piston", 3)
        direction = settings.get("direction_piston", 1)
        walls = [wall for wall in self.static_walls if wall[0] <= bounds[2] and bounds[0] <= wall[2]]
        self.pistons.append((bounds, speed, walls))
        self.piston_frames[0] += ((0, direction),)

    def _piston_state(self, tick):
        while tick >= len(self.piston_frames):
            positions = []
            for (bounds, speed, walls), (offset, direction) in zip(self.pistons, self.piston_frames[-1]):
                above = _move(bounds, dy=offset - 1 - speed)
                below = _move(bounds, dy=offset + 1 + speed)
                if any(_overlaps(above, wall) or _overlaps(below, wall) for wall in walls):
                    direction *= -1
                positions.append((offset + speed * direction, direction))
            self.piston_frames.append(tuple(positions))
        return self.piston_frames[tick]

    def _add_spinner(self, item):
        settings = self._settings(item)
        if item["name"] == "obj_shuriken3":
            angular_speed = settings.get("spd", 2) * settings.get("dir", 1)
        else:
            angular_speed = settings.get("speed_shuriken", 3) * settings.get("dir_shuriken", 1)
        obj = self.objects[item["name"]]
        sprite = self.sprites[obj["mask"] or obj["sprite"]]
        self.spinners.append(_spinner_masks(item, sprite, angular_speed))

    def _fall_frames(self, bounds, speed, offset=0.0):
        frames = [_for_player(_move(bounds, dy=int(offset)))]
        walls = [wall for wall in self.static_walls if wall[0] <= bounds[2] and bounds[0] <= wall[2]]
        while bounds[1] + offset < self.height:
            speed += 0.12
            offset += speed
            current = _move(bounds, dy=int(offset))
            if any(_overlaps(current, wall) for wall in walls):
                break
            frames.append(_for_player(current))
        return frames

    def spike_trigger_tick_at(self, state, x, y):
        trigger = getattr(state, "spike_trigger_tick", -1)
        if (trigger < 0 and self.fall_observation is None and self.fall_trigger
                and _contains(self.fall_trigger, x, y)):
            return state.tick
        return trigger

    def observe_falling(self, tick, records):
        """Align the falling spike with its current engine position and velocity."""
        if not self.fall_item:
            return
        spike = records.get(self.fall_item["id"])
        if spike is None:
            self.fall_observation = tick, ()
        elif spike[2]:
            _, y, _, speed = spike
            bounds = self._bounds(self.fall_item)
            self.fall_observation = tick, self._fall_frames(bounds, speed, y - self.fall_item["y"])
        else:
            self.fall_observation = None

    def _fall_at(self, state):
        if self.fall_observation is not None:
            observed_tick, frames = self.fall_observation
            age = max(0, state.tick - observed_tick)
        else:
            frames = self.fall or ()
            trigger = getattr(state, "spike_trigger_tick", -1)
            age = max(0, state.tick - trigger) if trigger >= 0 else 0
        return frames[age] if age < len(frames) else None

    def _frame(self, tick):
        danger = []
        for bounds, dx, dy, outbound, inbound, wait in self.pulses:
            offset = _pulse(tick, outbound, inbound, wait)
            danger.append(_move(bounds, int(dx * offset), int(dy * offset)))
        if self.chase:
            bounds, speed, stop_tick = self.chase
            danger.append(_move(bounds, dx=int(min(tick, stop_tick) * speed)))
        solid = ()
        if self.pistons:
            solid = tuple(_for_player(_move(bounds, dy=int(position[0])))
                          for (bounds, _, _), position in zip(self.pistons, self._piston_state(tick)))
        for arrow in self.arrows:
            fired, expire, x, y, velocity = arrow
            if fired <= tick < expire:
                center = int(x + (tick - fired) * velocity)
                danger.append((center - 68, y - 4, center + 68, y + 84))
        return danger, solid

    def solid_at(self, tick, x, y):
        if not self.pistons:
            return False
        return any(_contains(bounds, x, y) for bounds in self._forecast(tick)[1])

    def crushes_grounded_player(self, tick, x, y):
        if not self.pistons:
            return False
        # The piston moves first, then probes one pixel below its new position
        # while the grounded player is still at the previous frame's position.
        return any(_contains(bounds, x, y - 1) for bounds in self._forecast(tick)[1])

    def safe(self, state, x, y):
        falling = self._fall_at(state) if self.fall else None
        if falling and _contains(falling, x, y):
            return False
        hazard, _ = self._forecast(state.tick)
        if any(_contains(bounds, x, y) for bounds in hazard):
            return False
        if any(_spinner_hits(spinner[state.tick % len(spinner)], x, y) for spinner in self.spinners):
            return False
        return True

    def phase(self, state):
        """Keep nearby timing choices distinct without multiplying every air state."""
        if not self.active:
            return 0
        hazard, piston = self._forecast(state.tick)
        x, y = state.x, state.y
        if self.fall and _near(self.fall[0], x, y, 200):
            trigger = getattr(state, "spike_trigger_tick", -1)
            if trigger >= 0:
                return 1 + min(len(self.fall), state.tick - trigger) // 4
            if self.fall_observation is not None:
                observed_tick, frames = self.fall_observation
                return 1 + min(len(frames), state.tick - observed_tick) // 4
        if any(_near(bounds, x, y, 160) for bounds in hazard) or any(
            _near(bounds, x, y, 160) for bounds in piston
        ) or any(
            _near(spinner[state.tick % len(spinner)][0], x, y, 160) for spinner in self.spinners
        ):
            return 32 + (state.tick // 8) % 128
        return 0

    def _projectile(self, tick, x, y, velocity):
        walls = [wall for wall in self.static_walls + self.static_spikes
                 if wall[1] <= y + 4 and wall[3] >= y - 5]
        if velocity > 0:
            limit = min((wall[0] - 28 for wall in walls if wall[0] > x), default=self.width + 60)
            count = max(1, ceil((limit - x) / velocity))
        else:
            limit = max((wall[2] + 29 for wall in walls if wall[2] < x), default=-60)
            count = max(1, ceil((limit - x) / velocity))
        return tick, tick + count, x, y, velocity

    def observe_shooters(self, tick, records, arrows=()):
        """Use observed (instance ID, next alarm) and (x, y, velocity) tuples."""
        forecast = [self._projectile(tick, x, y, velocity) for x, y, velocity in arrows if velocity]
        for instance_id, alarm in records:
            shot = self.shooters.get(instance_id)
            if alarm > 0 and shot:
                forecast.append(self._projectile(tick + alarm, *shot))
        self.arrows = forecast
        self._forecast.cache_clear()
