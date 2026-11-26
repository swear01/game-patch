"""Plan keyboard input through the installed Minimalism game's physics."""

from collections import deque
from dataclasses import dataclass
import base64
from heapq import heappop, heappush
from itertools import count, permutations
import json
import math
from pathlib import Path
import re
from struct import Struct
from time import monotonic

import numpy as np

from search_memory import context_key


LEFT, RIGHT, JUMP = 1, 2, 4
PLAYER_LEFT, PLAYER_TOP, PLAYER_RIGHT, PLAYER_BOTTOM = -40, -80, 39, -1
ACTIONS = (LEFT, RIGHT, 0, LEFT | JUMP, RIGHT | JUMP, JUMP)
GRAVITY = 0.48
NORMAL_JUMP_SPEED = 12.8
WALL_JUMP_SPEED = 14.4
_F32 = Struct("<f")


def jump_rise(speed, launch_frame=False):
    rising_steps = max(0, math.ceil(speed / GRAVITY) - 1)
    rise = rising_steps * speed - GRAVITY * rising_steps * (rising_steps + 1) / 2
    return rise + (speed if launch_frame else 0)


NORMAL_JUMP_RISE = jump_rise(NORMAL_JUMP_SPEED, launch_frame=True)
WALL_JUMP_RISE = jump_rise(WALL_JUMP_SPEED)


def single_precision(value):
    return _F32.unpack(_F32.pack(value))[0]


def nearest_pixel(value):
    return int(value + 0.5)


def expired(deadline):
    return deadline is not None and monotonic() >= deadline


@dataclass(slots=True)
class State:
    x: float
    y: float
    hspd: float = 0
    vspd: float = 0
    grounded: bool = False
    state: int = 0
    jumps: int = 0
    wall_jumps: int = 0
    meet: int = 0
    wall_jump_can: int = 0
    invert_gravity: int = 1
    gravity_remaining: int = 0
    keys: int = 0
    tick: int = 0
    jump_held: bool = False
    finished: bool = False
    spike_trigger_tick: int = -1

    @classmethod
    def from_telemetry(cls, data):
        fields = {name: data[name] for name in cls.__dataclass_fields__ if name in data}
        if "second_alarm" in data:
            fields["gravity_remaining"] = max(0, data["second_alarm"])
        return cls(**fields)


@dataclass(frozen=True, slots=True)
class Rectangle:
    left: int
    top: int
    right: int
    bottom: int

    def for_player(self):
        return Rectangle(
            self.left - PLAYER_RIGHT,
            self.top - PLAYER_BOTTOM,
            self.right - PLAYER_LEFT,
            self.bottom - PLAYER_TOP,
        )

    def contains(self, x, y):
        return self.left <= x <= self.right and self.top <= y <= self.bottom

    def inset(self, x, y):
        return Rectangle(self.left + x, self.top + y, self.right - x, self.bottom - y)


def rectangle_for(instance, sprite):
    angle = math.radians(instance["rotation"])
    cosine = math.cos(angle)
    sine = math.sin(angle)
    corners = []
    for x in (sprite["left"], sprite["right"] + 1):
        for y in (sprite["top"], sprite["bottom"] + 1):
            sx = (x - sprite["originX"]) * instance["scaleX"]
            sy = (y - sprite["originY"]) * instance["scaleY"]
            corners.append(
                (
                    instance["x"] + cosine * sx + sine * sy,
                    instance["y"] - sine * sx + cosine * sy,
                )
            )
    left, top = (round(min(axis) + 1e-9) for axis in zip(*corners))
    right, bottom = (round(max(axis) + 1e-9) - 1 for axis in zip(*corners))
    return Rectangle(left, top, right, bottom)


def symbol_sprite(sprite, image_index):
    masks = sprite.get("bitmapMasks")
    if not masks or image_index is None or not 0 <= image_index < len(masks):
        return sprite
    raw_bits = np.unpackbits(np.frombuffer(base64.b64decode(masks[image_index]), dtype=np.uint8))
    mask = raw_bits.reshape(sprite["height"], -1)[:, :sprite["width"]]
    y, x = np.nonzero(mask)
    if not len(x):
        return sprite
    return {**sprite, "left": int(x.min()), "right": int(x.max()), "top": int(y.min()), "bottom": int(y.max())}


def fill(array, rectangle):
    height, width = array.shape
    x1 = max(0, rectangle.left)
    x2 = min(width, rectangle.right + 1)
    y1 = max(0, rectangle.top)
    y2 = min(height, rectangle.bottom + 1)
    if x1 < x2 and y1 < y2:
        array[y1:y2, x1:x2] = True


def brake(velocity, amount):
    return math.copysign(max(0.0, abs(velocity) - amount), velocity)


class Planner:
    GRID = 8

    def __init__(self, room, objects, sprites, code_dir=None, include_letters=False):
        self.room = room
        self.width = room["width"]
        self.height = room["height"]
        self.sample_position = nearest_pixel
        self.store_position = single_precision
        solid = np.zeros((self.height + 1, self.width + 1), dtype=np.bool_)
        self._solid = solid
        self._lethal = np.zeros_like(solid)
        self.death_observations = {}
        self.key_ids = []
        self.keys = []
        self.collectibles = []
        self.search_memory = None
        self.include_letters = include_letters
        self.door_key_mask = 0
        self.gravity_buttons = []
        self.goal = None
        self.start = None
        self.dynamic = None
        has_instance_settings = room["instances"] and "settings" in room["instances"][0]
        if (code_dir or has_instance_settings) and any(
            instance["name"].startswith(("obj_shuriken", "obj_shooter", "obj_spike_move", "obj_piston"))
            or instance["name"] in ("obj_spike_fall", "obj_spike_wall1", "obj_button_grav")
            for instance in room["instances"]
        ):
            try:
                from hazards import DynamicWorld
            except ImportError as error:
                if error.name != "hazards":
                    raise
            else:
                self.dynamic = DynamicWorld(self, {"objects": objects, "sprites": sprites}, code_dir)
        for instance in room["instances"]:
            name = instance["name"]
            if name == "obj_player":
                self.start = State(instance["x"], instance["y"])
            obj = objects[name]
            sprite = sprites.get(obj["mask"] or obj["sprite"])
            if not sprite:
                continue
            rect = rectangle_for(instance, sprite).for_player()
            parent = name
            while parent and parent != "obj_wall_general":
                parent = objects[parent]["parent"]
            if parent == "obj_wall_general" and not (
                self.dynamic and name in ("obj_piston2", "obj_piston3")
            ):
                fill(solid, rect)
            if name in ("obj_spike", "obj_spike_min"):
                fill(self._lethal, rect)
            if name == "obj_door":
                self.goal = rect
            if name == "obj_key" or (include_letters and name in ("obj_bonus_jp", "obj_bonus_eng")):
                image_index = instance.get("settings", {}).get("image_index", instance.get("image_index"))
                if image_index is not None:
                    image_index = int(image_index)
                if name == "obj_key":
                    self.door_key_mask |= 1 << len(self.keys)
                else:
                    rect = rectangle_for(instance, symbol_sprite(sprite, image_index)).for_player()
                self.key_ids.append(instance["id"])
                self.collectibles.append({"id": instance["id"], "name": name, "image_index": image_index})
                self.keys.append(rect.inset(2, 11) if name == "obj_key" else rect.inset(7, 13))
            if name == "obj_button_grav":
                duration = int(instance.get("settings", {}).get("time_gravity", 30))
                if not has_instance_settings and code_dir and instance["code"]:
                    code = Path(code_dir, instance["code"] + ".gml").read_text(encoding="utf-8-sig")
                    match = re.search(r"\btime_gravity\s*=\s*(\d+)", code)
                    if match:
                        duration = int(match[1])
                self.gravity_buttons.append((Rectangle(rect.left, rect.top - 2, rect.right, rect.bottom - 2), duration))
        self.solid = memoryview(solid)
        self.lethal = memoryview(self._lethal)
        self.grid = (solid | self._lethal)[:: self.GRID, :: self.GRID]
        self.distance_maps = {}
        self._climbing_support = None
        self._ceiling_support = None
        self._contact_cells = None
        self._horizontal_clearance = None
        self.all_keys = (1 << len(self.keys)) - 1
        self.required_ids = tuple(self.key_ids)
        self.collectible_ids = self.required_ids
        self.chase_room = self.dynamic is not None and self.dynamic.chase is not None
        self._piston_crush = getattr(self.dynamic, "crushes_grounded_player", None)

    @classmethod
    def from_export(cls, export, level, code_dir=None, include_letters=False):
        if not isinstance(export, dict):
            path = Path(export)
            export = json.loads(path.read_text(encoding="utf-8-sig"))
            if code_dir is None and (path.parent / "CodeEntries").is_dir():
                code_dir = path.parent / "CodeEntries"
        name = f"rm_level_{level:02d}"
        room = next(room for room in export["rooms"] if room["name"] == name)
        return cls(room, export["objects"], export["sprites"], code_dir, include_letters)

    def with_remaining_keys(self, state, remaining_ids):
        key_mask = sum(1 << index for index, key_id in enumerate(self.key_ids) if key_id not in remaining_ids)
        state.keys = key_mask
        return state

    def observe(self, checkpoint):
        if not self.dynamic:
            return
        tick = checkpoint["tick"]
        self.dynamic.observe_shooters(tick, checkpoint["shooters"].items(), checkpoint["arrows"])
        observe_falling = getattr(self.dynamic, "observe_falling", None)
        if observe_falling:
            observe_falling(tick, checkpoint["falling"])

    def avoid_death(self, cause, x, y, tick):
        """Remember death neighborhoods for ranking. Geometry decides collisions."""
        x, y, tick = float(x), float(y), int(tick)
        ix, iy = self.sample_position(x), self.sample_position(y)
        if cause in ("obj_spike", "obj_spike_min"):
            phase = None
        elif cause.startswith(("obj_shuriken", "obj_spike_move", "obj_spike_fall", "obj_piston", "obj_arrow")):
            phase = tick
        else:
            return
        for cy in range((iy - 8) // 16, (iy + 8) // 16 + 1):
            for cx in range((ix - 8) // 16, (ix + 8) // 16 + 1):
                self.death_observations.setdefault((cx, cy), set()).add((ix, iy, phase))

    def death_priority(self, state):
        region = int(state.x) // 16, int(state.y) // 16
        return min(96, 16 * sum(
            abs(state.x - x) <= 8 and abs(state.y - y) <= 8 and (tick is None or abs(state.tick - tick) <= 7)
            for x, y, tick in self.death_observations.get(region, ())
        ))

    def step(self, old, action):
        x, y = old.x, old.y
        h, v = old.hspd, old.vspd
        solid, lethal = self.solid, self.lethal
        dynamic = self.dynamic
        piston_solid = dynamic.solid_at if dynamic is not None and dynamic.pistons else None
        next_tick = old.tick + 1
        sample, store = self.sample_position, self.store_position

        def collides(px, py):
            return solid[py, px] or (piston_solid is not None and piston_solid(next_tick, px, py))

        side = (action & RIGHT != 0) - (action & LEFT != 0)
        jump = bool(action & JUMP)
        wall_state = old.state
        jumps, wall_jumps = old.jumps, old.wall_jumps
        meet, wall_jump_can = old.meet, old.wall_jump_can
        gravity, gravity_remaining = old.invert_gravity, old.gravity_remaining
        if gravity_remaining > 0:
            gravity_remaining -= 1
            if gravity_remaining == 0:
                gravity = 1
        # The native runner rounds the target position before mask placement.
        # A one-pixel move outside the room counts as a boundary during planning.
        ix, iy = sample(x), sample(y)
        if not (1 <= ix < self.width and 1 <= iy < self.height):
            return None
        # Begin Step probes the previous positions. The pistons move before
        # the player's Step uses wall and floor geometry to resolve motion.
        grounded = bool(solid[iy + gravity, ix] or (
            piston_solid is not None and piston_solid(old.tick, ix, iy + gravity)
            and not piston_solid(old.tick, ix, iy)
        ))
        if grounded and self._piston_crush and self._piston_crush(next_tick, ix, iy):
            return None
        integrate = True
        if wall_state == 2:
            if old.jump_held and not jump:
                wall_state = 0
                integrate = False
            else:
                h = max(-8, min(8, h + (2 if meet > 0 else -2)))
                if not (0 <= sample(x + h) <= self.width) or collides(sample(x + h), iy) or grounded:
                    wall_state = 0
                h = brake(h, 0.2)
        else:
            h = max(-8, min(8, h + 2 * side))
            if grounded and not jump:
                jumps, wall_jumps, wall_jump_can = 1, 0, 0
            if jump and jumps > 0 and grounded:
                jumps -= 1
                v = -NORMAL_JUMP_SPEED * gravity
            h = brake(h, 0.4 if grounded else 0.2)
            left = bool(collides(ix - 1, iy))
            right = bool(collides(ix + 1, iy))
            if not grounded and (left or right):
                meet = left - right
                if wall_jump_can != meet:
                    wall_jump_can = 0
                if not jump:
                    v = 4 * gravity
                    wall_jumps = 1
                if jump and wall_jumps > 0:
                    wall_jumps -= 1
                    wall_jump_can = meet
                    wall_state = 2
                    h = 4 * meet
                    v = -WALL_JUMP_SPEED * gravity
        if integrate:
            hx = sample(x + h)
            if hx < 1 or hx >= self.width:
                return None
            if collides(hx, iy):
                direction = (h > 0) - (h < 0)
                while direction and not collides(sample(x + direction), iy):
                    x = store(x + direction)
                h = 0
            x = store(x + h)
            ix = sample(x)
            if not collides(ix, iy + gravity):
                v += GRAVITY * gravity
            if wall_state != 2:
                v = gravity * min(v * gravity, 22.4)
            vy = sample(y + v)
            if vy < 1 or vy >= self.height:
                return None
            if collides(ix, vy):
                direction = (v > 0) - (v < 0)
                while direction and not collides(ix, sample(y + direction)):
                    y = store(y + direction)
                v = 0
            y = store(y + v)
            iy = sample(y)
        if lethal[iy, ix]:
            return None
        keys = old.keys
        for index, key in enumerate(self.keys):
            if key.contains(ix, iy):
                keys |= 1 << index
        for button, duration in self.gravity_buttons:
            if gravity == 1 and button.contains(ix, iy):
                gravity, gravity_remaining = -1, duration
        enters_door = (keys & self.door_key_mask) == self.door_key_mask and self.goal.contains(ix, iy)
        if self.include_letters and enters_door and keys != self.all_keys:
            return None
        finished = enters_door and keys == self.all_keys
        new = State(
            x, y, h, v, grounded, wall_state, jumps, wall_jumps, meet, wall_jump_can,
            gravity, gravity_remaining, keys, next_tick, jump, finished, old.spike_trigger_tick,
        )
        if dynamic:
            new.spike_trigger_tick = dynamic.spike_trigger_tick_at(new, ix, iy)
            if not dynamic.safe(new, ix, iy):
                return None
        return new

    def _support_grid(self, ceiling=False):
        cache = self._ceiling_support if ceiling else self._climbing_support
        if cache is not None:
            return cache
        walls = self._solid[:: self.GRID, :: self.GRID]
        hazards = self._lethal[:: self.GRID, :: self.GRID]
        height, width = walls.shape
        support = np.zeros((height, width), dtype=np.bool_)
        floor_distance = np.full(width, 1000, dtype=np.int16)
        rows = range(height) if ceiling else range(height - 1, -1, -1)
        for y in rows:
            floor_distance += 1
            floor_distance[walls[y]] = 0
            floor_distance[hazards[y]] = 1000
            support[y] = floor_distance <= math.ceil(NORMAL_JUMP_RISE / self.GRID)
        for offset in (1, 2, 3):
            support[:, offset:] |= walls[:, :-offset]
            support[:, :-offset] |= walls[:, offset:]
        padded = np.ones((height + 2, width + 2), dtype=np.bool_)
        padded[1:-1, 1:-1] = support
        cache = memoryview(padded).cast("B")
        if ceiling:
            self._ceiling_support = cache
        else:
            self._climbing_support = cache
        return cache

    def _contact_grid(self):
        if self._contact_cells is None:
            height, width = self.grid.shape
            padded = np.pad(self.grid, 2, constant_values=True)
            nearby = np.zeros_like(self.grid)
            for dy in (0, 2, 4):
                for dx in (0, 2, 4):
                    nearby |= padded[dy:dy + height, dx:dx + width]
            self._contact_cells = memoryview(nearby)
        return self._contact_cells

    def rise_to(self, state, goal):
        return max(0, state.y - goal.bottom) if state.invert_gravity > 0 else max(0, goal.top - state.y)

    def available_rise(self, state):
        if state.grounded:
            return NORMAL_JUMP_RISE
        if state.wall_jumps or state.state == 2:
            return max(WALL_JUMP_RISE, jump_rise(max(0, -state.vspd * state.invert_gravity)))
        return jump_rise(max(0, -state.vspd * state.invert_gravity))

    def _clearance_grid(self):
        if self._horizontal_clearance is not None:
            return self._horizontal_clearance
        height, width = self.grid.shape
        up = np.zeros((height, width), dtype=np.uint8)
        down = np.zeros_like(up)
        for y in range(1, height):
            up[y] = np.where(self.grid[y], 0, np.minimum(up[y - 1] + 1, 8))
        for y in range(height - 2, -1, -1):
            down[y] = np.where(self.grid[y], 0, np.minimum(down[y + 1] + 1, 8))
        roomy = up + down >= 6
        padded = np.ones((height + 2, width + 2), dtype=np.bool_)
        padded[1:-1, 1:-1] = roomy
        self._horizontal_clearance = memoryview(padded).cast("B")
        return self._horizontal_clearance

    def _distance_map(self, goal, supported=False, deadline=None):
        cache_key = (goal, supported)
        if cache_key in self.distance_maps:
            return self.distance_maps[cache_key]
        if expired(deadline):
            return None
        blocked = self.grid
        height, width = blocked.shape
        # Byte-addressable storage is faster than NumPy scalar indexing inside the queue loop.
        never = 0x7FFF
        d = np.full((height + 2, width + 2), never, dtype=np.uint16)
        d[0, :] = d[-1, :] = d[:, 0] = d[:, -1] = 0
        interior = d[1:-1, 1:-1]
        interior[blocked] = 0
        stride = width + 2
        data = memoryview(d).cast("B").cast("H")
        buckets = tuple(deque() for _ in range(13 if supported == "standing" else 5 if supported else 1))
        count_pending = 0
        for y in range(max(0, math.ceil(goal.top / self.GRID)), min(height - 1, goal.bottom // self.GRID) + 1):
            for x in range(max(0, math.ceil(goal.left / self.GRID)), min(width - 1, goal.right // self.GRID) + 1):
                if not blocked[y, x]:
                    position = (y + 1) * stride + x + 1
                    data[position] = 0
                    buckets[0].append(position)
                    count_pending += 1
        if supported:
            supports = self._support_grid(ceiling=supported == "ceiling")
            clearance = self._clearance_grid() if supported == "standing" else None
            rising = -stride if supported == "ceiling" else stride
            distance = 0
            processed = 0
            while count_pending:
                bucket = buckets[distance % len(buckets)]
                if not bucket:
                    distance += 1
                    continue
                position = bucket.popleft()
                count_pending -= 1
                processed += 1
                if processed % 256 == 0 and expired(deadline):
                    return None
                if data[position] != distance:
                    continue
                for offset in (-1, 1, -stride, stride):
                    neighbor = position + offset
                    moving_sideways = abs(offset) == 1
                    uses_support = offset == rising or (clearance is not None and moving_sideways)
                    step_cost = 4 if uses_support and not supports[neighbor] else 1
                    if clearance is not None and moving_sideways and not clearance[neighbor]:
                        step_cost += 8
                    cost = distance + step_cost
                    if data[neighbor] > cost:
                        data[neighbor] = cost
                        buckets[cost % len(buckets)].append(neighbor)
                        count_pending += 1
        else:
            queue = buckets[0]
            processed = 0
            while queue:
                position = queue.popleft()
                processed += 1
                if processed % 256 == 0 and expired(deadline):
                    return None
                distance = data[position] + 1
                for neighbor in (position - 1, position + 1, position - stride, position + stride):
                    if data[neighbor] == never:
                        data[neighbor] = distance
                        queue.append(neighbor)
        interior[blocked] = never
        result = memoryview(interior)
        self.distance_maps[cache_key] = result
        return result

    def _distance_estimate(self, goal, supported=False, deadline=None):
        distances = self._distance_map(goal, supported, deadline)
        if distances is None:
            return None
        grid, width, height = self.GRID, distances.shape[1], distances.shape[0]

        def estimate(state):
            ix, iy = round(state.x / grid), round(state.y / grid)
            coarse = distances[max(0, min(height - 1, iy)), max(0, min(width - 1, ix))]
            if coarse >= 0x7FFF:
                coarse = 0x7FFF
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        gx, gy = ix + dx, iy + dy
                        if 0 <= gx < width and 0 <= gy < height:
                            coarse = min(coarse, distances[gy, gx] + 1)
            if coarse >= 0x7FFF:
                return 10000 + (abs(state.x - (goal.left + goal.right) / 2) + abs(state.y - (goal.top + goal.bottom) / 2)) / grid
            return coarse
        return estimate

    def search(self, initial, goal, until, max_nodes=160000, primitive=5, heuristic_weight=4, precision=7,
               estimate=None, deadline=None, alternative=None):
        estimate = estimate or self._distance_estimate(goal, deadline=deadline)
        if estimate is None or expired(deadline):
            return None
        sequence = count()
        seen = {}
        expanded = {}
        phase = getattr(self.dynamic, "phase", None)
        memory = self.search_memory
        contacts = self._contact_grid()
        grid_height, grid_width = contacts.shape

        def fingerprint(s):
            cell_x = max(0, min(grid_width - 1, round(s.x / self.GRID)))
            cell_y = max(0, min(grid_height - 1, round(s.y / self.GRID)))
            refined = contacts[cell_y, cell_x]
            space = max(2, precision // 2) if refined else precision
            velocity = 1 if refined else 2
            contact = 0
            if refined:
                x = max(1, min(self.width - 1, self.sample_position(s.x)))
                y = max(1, min(self.height - 1, self.sample_position(s.y)))
                contact = (self.solid[y, x - 1] | (self.solid[y, x + 1] << 1)
                           | (self.solid[y - 1, x] << 2) | (self.solid[y + 1, x] << 3))
            return (
                contact, refined, round(s.x / space), round(s.y / space), round(s.hspd / velocity), round(s.vspd / velocity),
                s.grounded, s.state, s.jumps, s.wall_jumps, s.meet, s.wall_jump_can, s.invert_gravity,
                s.gravity_remaining // 5, s.keys, s.jump_held,
                phase(s) if phase else 0,
            )

        def recover(link):
            reversed_actions = []
            while link:
                action, ticks, link = link
                reversed_actions.extend([action] * ticks)
            return reversed_actions[::-1]

        queue = []
        alternate_queue = []

        def enqueue(state, steps, link, signature):
            seen[signature] = steps
            order = next(sequence)
            record = (steps, state, link, signature)
            penalty = self.death_priority(state) if self.death_observations else 0
            if memory is not None and memory.counts:
                key = context_key(state, goal, remaining=self.all_keys & ~state.keys, phase=signature[-1])
                penalty += memory.penalty(key)
            heappush(queue, (steps + heuristic_weight * estimate(state) + penalty, steps, order, record))
            if alternative is not None:
                weight = min(18, max(8, heuristic_weight * 2))
                heappush(alternate_queue, (steps + weight * alternative(state) + penalty, steps, order, record))

        enqueue(initial, 0, None, fingerprint(initial))
        nodes = 0
        pops = 0
        while nodes < max_nodes and (queue or alternate_queue):
            if pops % 64 == 0 and expired(deadline):
                break
            choice = alternate_queue if alternate_queue and (not queue or pops % 4 == 3) else queue
            _, _, _, (steps, state, link, signature) = heappop(choice)
            pops += 1
            if steps != seen[signature] or steps >= expanded.get(signature, math.inf):
                continue
            expanded[signature] = steps
            nodes += 1
            if until(state):
                return recover(link), state
            for action in ACTIONS:
                future = state
                for frames in range(1, primitive + 1):
                    future = self.step(future, action)
                    if future is None:
                        break
                    if until(future):
                        return recover((action, frames, link)), future
                if future is None:
                    continue
                total = steps + primitive
                signature = fingerprint(future)
                if total >= seen.get(signature, math.inf):
                    continue
                enqueue(future, total, (action, primitive, link), signature)
        return None

    _VARIANTS = ((5, 4, 7), (8, 8, 7), (4, 10, 6), (6, 12, 7), (3, 6, 5), (7, 18, 6), (2, 15, 4), (9, 6, 9))

    def objective_order(self, state, attempt=0, deadline=None):
        """Rank both kinds of pickups by the same movement costs."""
        if isinstance(state, dict):
            state = State.from_telemetry(state)
        indices = [index for index in range(len(self.keys)) if not state.keys & (1 << index)]
        if not indices:
            return [-1]
        if self.chase_room and self.include_letters:
            return sorted(indices, key=lambda index: self.keys[index].left)
        estimates = {index: self._distance_estimate(self.keys[index], deadline=deadline) for index in indices}
        rise = self.available_rise(state)
        indices.sort(key=lambda index: (
            estimates[index](state) + max(0, self.rise_to(state, self.keys[index]) - rise) / self.GRID
            if estimates[index] else math.inf
        ))
        turn = (attempt // len(self._VARIANTS)) % len(indices)
        return indices[turn:] + indices[:turn]

    def _can_continue(self, state, ticks=12):
        if state.finished:
            return True
        for action in ACTIONS:
            future = state
            for _ in range(ticks):
                future = self.step(future, action)
                if future is None:
                    break
            if future is not None:
                return True
        return False

    def plan_segment(self, state, max_nodes=20000, attempt=0, min_steps=1, supported=False,
                     objective=None, deadline=None, shared_search=False):
        """Find a closer reachable pose using the live state and the next objective."""
        if isinstance(state, dict):
            state = State.from_telemetry(state)
        choices = self.objective_order(state, attempt, deadline) if objective is None else [objective]
        primitive, weight, precision = self._VARIANTS[attempt % len(self._VARIANTS)]
        for index in choices:
            goal = self.goal if index == -1 else self.keys[index]
            mode = supported or ("standing" if self.rise_to(state, goal) > self.available_rise(state) + 24 else False)

            def until(future):
                return future.finished if index == -1 else bool(future.keys & (1 << index))

            estimate = self._distance_estimate(goal, mode, deadline)
            if estimate is None or expired(deadline):
                break
            initial = estimate(state)
            progress = initial - min(25, max(10, initial // 5))
            alternative = self._distance_estimate(goal, False if mode else "standing", deadline) if shared_search else None
            alternate_initial = alternative(state) if alternative else 10000
            alternate_progress = alternate_initial - min(25, max(10, alternate_initial // 5))

            def closer(future):
                reached = until(future) or (
                    progress >= 5
                    and future.tick >= state.tick + min_steps
                    and (estimate(future) <= progress or (
                        alternative is not None and alternate_initial < 10000
                        and alternative(future) <= alternate_progress and estimate(future) <= initial + 8
                    ))
                )
                return reached and self._can_continue(future)

            result = self.search(state, goal, closer, max_nodes, primitive, weight, precision, estimate, deadline,
                                 alternative=alternative)
            if result:
                return result
        return None

    def plan_hierarchical(self, state=None, max_nodes=22000, attempt=0, deadline=None):
        """Repeat local kinematic searches until the live game's exit is reached."""
        if state is None:
            state = self.start
        if isinstance(state, dict):
            state = State.from_telemetry(state)
        result = []
        history = [(state, 0, 0, None)]
        explored = set()
        options = ((0, False), (0, True), (1, False), (1, True), (2, False), (2, True))
        if self.include_letters:
            options += ((0, "standing"), (2, "standing"))
        for _ in range(500):
            if state.finished:
                return result
            if expired(deadline):
                break
            state, before, option, objective = history[-1]
            if option >= len(options):
                if len(history) == 1:
                    break
                history.pop()
                state, before, option, objective = history[-1]
                del result[before:]
                continue
            history[-1] = state, before, option + 1, objective
            offset, supported = options[option]
            requested = objective
            if requested is None:
                order = self.objective_order(state, attempt, deadline)
                requested = order[min(option // 2, len(order) - 1)]
            segment = self.plan_segment(
                state, max_nodes, attempt + offset, supported=supported, objective=requested, deadline=deadline,
            )
            if not segment or not segment[0]:
                continue
            actions, future = segment
            fingerprint = (round(future.x / 5), round(future.y / 5), round(future.hspd / 2),
                           round(future.vspd / 2), future.keys, future.invert_gravity,
                           future.gravity_remaining // 4, future.state, future.jump_held)
            if self.dynamic:
                fingerprint += (self.dynamic.phase(future),)
            if fingerprint in explored:
                continue
            explored.add(fingerprint)
            result.extend(actions)
            if future.keys != state.keys:
                requested = None
            state = future
            history.append((state, len(result), 0, requested))
        return None

    def ranked_orders(self, state, width=18, deadline=None):
        """Rank collection tours using the traversable space in the room."""
        indices = tuple(index for index in range(len(self.keys)) if not state.keys & (1 << index))
        if not indices:
            return [()]
        if self.chase_room:
            return [tuple(sorted(indices, key=lambda index: self.keys[index].left))]

        def rectangle(index):
            return self.goal if index == -1 else self.keys[index]

        def point(index):
            goal = rectangle(index)
            return State((goal.left + goal.right) / 2, (goal.top + goal.bottom) / 2)

        origins = {-2: state, **{index: point(index) for index in indices}}
        distances = {}
        for end in (*indices, -1):
            heuristic = self._distance_estimate(rectangle(end), deadline=deadline)
            if heuristic is None or expired(deadline):
                return []
            distances[end] = {start: heuristic(pose) for start, pose in origins.items()}

        if len(indices) <= 6:
            def itinerary_cost(order):
                path = (-2, *order, -1)
                return sum(distances[end][start] for start, end in zip(path, path[1:]))

            return sorted(permutations(indices), key=itinerary_cost)[:width]

        # Keep a bounded set for dense rooms instead of enumerating factorially many tours.
        current = [(0, (), indices)]
        for _ in indices:
            choices = []
            for score, path, pending in current:
                previous = path[-1] if path else -2
                for end in pending:
                    choices.append((score + distances[end][previous], path + (end,),
                                    tuple(index for index in pending if index != end)))
            current = sorted(choices, key=lambda candidate: candidate[0] + distances[-1][candidate[1][-1]])[:width]
        return [path for _, path, _ in current]

    def sweep_orders(self, state, deadline=None):
        """Sweep each side of an obstacle field before changing sides."""
        indices = self.objective_order(state, deadline=deadline)
        if indices == [-1]:
            return [()]
        if self.chase_room:
            return [tuple(indices)]
        first, *others = indices

        def horizontal(index):
            goal = self.keys[index]
            return (goal.left + goal.right) / 2

        def vertical(index):
            goal = self.keys[index]
            return (goal.top + goal.bottom) / 2

        sign = 1 if state.x >= horizontal(first) else -1
        distant = [index for index in others if (horizontal(index) - horizontal(first)) * sign < 0]
        near = [index for index in others if index not in distant]
        return [
            (first, *sorted(distant, key=vertical, reverse=reverse),
             *sorted(near, key=vertical, reverse=not reverse))
            for reverse in (True, False)
        ]

    def plan_ordered(self, state=None, max_nodes=18000, attempt=0, deadline=None, trace=None,
                     sweep=False):
        """Try calculated collection tours with multiple input timings per leg."""
        if state is None:
            state = self.start
        if isinstance(state, dict):
            state = State.from_telemetry(state)
        plans = {}
        platform_routes = None
        options = ((8, 8, False), (4, 10, False), (6, 12, False), (5, 4, False))
        if sweep:
            options = ((8, 8, False), (4, 10, False), (5, 8, True), (8, 8, "standing"))
        route_options = self.sweep_orders(state, deadline) if sweep else self.ranked_orders(state, deadline=deadline)
        if route_options:
            turn = (attempt // len(self._VARIANTS)) % len(route_options)
            route_options = route_options[turn:] + route_options[:turn]
        for order in route_options:
            if expired(deadline):
                return None
            pose, controls, prefix = state, [], ()
            for objective in (*order, -1):
                prefix += (objective,)
                if prefix not in plans:
                    target = self.goal if objective == -1 else self.keys[objective]

                    def attained(future):
                        if objective == -1:
                            return future.finished
                        return bool(future.keys & (1 << objective)) and self._can_continue(future, 12 if sweep else 18)

                    result = None
                    if (objective != -1 and self.include_letters and self.gravity_buttons
                            and self.all_keys & ~pose.keys == 1 << objective):
                        from platforms import approach_inverted_collectible

                        local_deadline = min(deadline, monotonic() + 8) if deadline is not None else monotonic() + 8
                        result = approach_inverted_collectible(self, pose, objective, max_nodes, deadline=local_deadline)
                    for stride, weight, mode in options:
                        if result is not None:
                            break
                        local_deadline = min(deadline, monotonic() + 4) if deadline is not None else None
                        estimate = self._distance_estimate(target, mode, local_deadline)
                        if estimate is None:
                            break
                        result = self.search(
                            pose, target, attained, max_nodes, stride, weight, 5,
                            estimate=estimate, deadline=local_deadline,
                        )
                        if result is not None or expired(deadline):
                            break
                    if (result is None and objective != -1 and not expired(deadline)
                            and self.rise_to(pose, target) > self.available_rise(pose)):
                        from platforms import approach_collectible_from_wall

                        local_deadline = min(deadline, monotonic() + 6) if deadline is not None else monotonic() + 6
                        result = approach_collectible_from_wall(self, pose, objective, max_nodes, deadline=local_deadline)
                    if result is None and sweep and not expired(deadline):
                        from beam import _progress

                        local_deadline = min(deadline, monotonic() + 12) if deadline is not None else monotonic() + 12
                        estimate = self._distance_estimate(target, "standing", local_deadline)
                        if estimate is not None:
                            progress = _progress(self, pose, estimate, attained, min(max_nodes, 6500), 13, local_deadline)
                            if progress is not None:
                                end, inputs = progress
                                result = list(map(int, inputs)), end
                    if result is None and not expired(deadline) and not self.chase_room:
                        if platform_routes is None:
                            from platforms import PlatformRoutes

                            platform_routes = PlatformRoutes(self, deadline, wall_nodes=sweep)
                        local_deadline = min(deadline, monotonic() + 10) if deadline is not None else None
                        result = platform_routes.to(
                            pose, target, attained, min(max_nodes, 3500), deadline=local_deadline,
                        )
                    if result is None and objective == -1 and self.include_letters and not expired(deadline):
                        from platforms import plan_portal_exit

                        local_deadline = min(deadline, monotonic() + 14) if deadline is not None else None
                        controls_to_portal = plan_portal_exit(self, pose, max_nodes, deadline=local_deadline)
                        if controls_to_portal:
                            end = pose
                            for action in controls_to_portal:
                                end = self.step(end, action)
                            result = controls_to_portal, end
                    if result is None and objective == -1 and self.include_letters and not expired(deadline):
                        local_deadline = min(deadline, monotonic() + 5) if deadline is not None else None
                        estimate = self._distance_estimate(target, "standing", local_deadline)
                        if estimate is not None:
                            result = self.search(
                                pose, target, attained, max_nodes, 5, 8, 5,
                                estimate=estimate, deadline=local_deadline,
                            )
                    if (result is not None and objective >= 0 and result[1].vspd > 4
                            and not self.door_key_mask & (1 << objective) and not expired(deadline)):
                        from platforms import stabilize_wall_pickup

                        local_deadline = monotonic() + 4
                        if deadline is not None:
                            local_deadline = min(local_deadline, deadline)
                        stabilized = stabilize_wall_pickup(self, pose, objective, result[0],
                                                          max_nodes, local_deadline)
                        if stabilized is not None:
                            result = stabilized
                    plans[prefix] = result
                    if trace:
                        trace(order, objective, None if result is None else result[1])
                if plans[prefix] is None:
                    break
                segment, pose = plans[prefix]
                controls += segment
            else:
                return controls
        return None

    def plan(self, state=None, max_nodes=160000, attempt=0, deadline=None):
        if state is None:
            state = self.start
        if isinstance(state, dict):
            state = State.from_telemetry(state)
        primitive, weight, precision = self._VARIANTS[attempt % len(self._VARIANTS)]

        def route_to(state, goal, until):
            return self.search(state, goal, until, max_nodes, primitive, weight, precision, deadline=deadline)

        result = []
        first = True
        while state.keys != self.all_keys:
            if expired(deadline):
                return None
            remaining = [(i, key) for i, key in enumerate(self.keys) if not state.keys & (1 << i)]
            if self.chase_room and self.include_letters:
                remaining.sort(key=lambda pair: pair[1].left)
                remaining = remaining[:1]
            else:
                remaining.sort(
                    key=lambda pair: (state.x - (pair[1].left + pair[1].right) / 2) ** 2
                    + (state.y - (pair[1].top + pair[1].bottom) / 2) ** 2
                )
            if first and attempt >= len(self._VARIANTS) and not (self.chase_room and self.include_letters):
                rotate = (attempt // len(self._VARIANTS)) % len(remaining)
                remaining = remaining[rotate:] + remaining[:rotate]
            found = None
            for index, goal in remaining:
                def collects(s):
                    return bool(s.keys & (1 << index)) and (
                        not self.include_letters or self._can_continue(s, 18)
                    )

                found = route_to(state, goal, collects)
                if found:
                    break
            if found is None:
                return None
            actions, state = found
            result.extend(actions)
            first = False
        found = route_to(state, self.goal, lambda s: s.finished)
        if found is None:
            return None
        actions, _ = found
        return result + actions


if __name__ == "__main__":
    import argparse
    import time

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", type=Path)
    parser.add_argument("level", type=int)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--attempt", type=int, default=0)
    parser.add_argument("--max-nodes", type=int, default=160000)
    parser.add_argument("--hierarchical", action="store_true")
    parser.add_argument("--include-letters", action="store_true")
    args = parser.parse_args()
    started = time.perf_counter()
    planner = Planner.from_export(args.export, args.level, include_letters=args.include_letters)
    solve = planner.plan_hierarchical if args.hierarchical else planner.plan
    plan = solve(max_nodes=args.max_nodes, attempt=args.attempt)
    if not plan:
        raise SystemExit(f"No plan for room {args.level} after {time.perf_counter() - started:.1f} s")
    if args.output:
        args.output.write_text("".join(str(action) for action in plan), encoding="ascii")
    print(f"Room {args.level}: {len(plan)} inputs in {time.perf_counter() - started:.1f} s")
