import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const input = process.argv[2] ?? fileURLToPath(new URL('../data.original.win', import.meta.url));
const output = process.argv[3];
const bytes = readFileSync(input);
const uint = offset => bytes.readUInt32LE(offset);
const signed = offset => bytes.readInt32LE(offset);
const float = offset => bytes.readFloatLE(offset);

if (bytes.toString('ascii', 0, 4) !== 'FORM' || uint(4) + 8 !== bytes.length) {
    throw new Error('Expected an intact Shelldiver data.win FORM file.');
}

const chunks = new Map();
for (let offset = 8; offset < bytes.length;) {
    const name = bytes.toString('ascii', offset, offset + 4);
    const length = uint(offset + 4);
    const next = offset + 8 + length;
    if (next > bytes.length) throw new Error(`GameMaker chunk ${name} is truncated.`);
    chunks.set(name, offset + 8);
    offset = next;
}

function pointers(offset) {
    if (!Number.isSafeInteger(offset) || offset < 8 || offset + 4 > bytes.length) {
        throw new Error('Missing or invalid GameMaker pointer table.');
    }
    const count = uint(offset);
    if (offset + 4 + count * 4 > bytes.length) throw new Error('Truncated GameMaker pointer table.');
    return Array.from({ length: count }, (_, index) => uint(offset + 4 + index * 4));
}

function nameAt(pointer) {
    if (pointer < 4 || pointer > bytes.length) throw new Error('Invalid GameMaker name pointer.');
    const end = pointer + uint(pointer - 4);
    if (end > bytes.length) throw new Error('Truncated GameMaker name.');
    return bytes.toString('utf8', pointer, end);
}

const roomName = 'rm_skill_tree';
const room = pointers(chunks.get('ROOM')).find(offset => nameAt(uint(offset)) === roomName);
if (!room) throw new Error(`Could not find ${roomName}.`);

const objectNames = pointers(chunks.get('OBJT')).map(offset => nameAt(uint(offset)));
const sprites = pointers(chunks.get('SPRT'));
const arrowNames = new Map([
    ['o_skill_arrow_any', ['anyLevel', 's_skill_arrow_any']],
    ['o_skill_arrow_max', ['maxLevel', 's_skill_arrow_all']]
]);

const nodes = {};
const arrowPlacements = [];
// These offsets describe the instance record in the installed Shelldiver stock data.
for (const offset of pointers(uint(room + 48))) {
    const objectIndex = uint(offset + 8);
    const id = objectNames[objectIndex];
    if (!id?.startsWith('o_skill_')) continue;

    const position = { x: signed(offset), y: signed(offset + 4) };
    const instanceId = uint(offset + 12);
    const arrow = arrowNames.get(id);
    if (arrow) {
        const [requirement, sprite] = arrow;
        arrowPlacements.push({
            instanceId, ...position, requirement, sprite,
            scale: float(offset + 20), rotation: float(offset + 40)
        });
        continue;
    }

    if (Object.hasOwn(nodes, id)) throw new Error(`Duplicate skill object ${id}.`);
    nodes[id] = { objectIndex, instanceId, ...position, needsAnyLevel: [], needsMaxLevel: [] };
}

const spriteWidths = new Map();
for (const [, sprite] of arrowNames.values()) {
    const offset = sprites.find(offset => nameAt(uint(offset)) === sprite);
    if (!offset) throw new Error(`Could not find arrow sprite ${sprite}.`);
    spriteWidths.set(sprite, uint(offset + 4));
}

function nodeAt(x, y) {
    const candidates = Object.entries(nodes).filter(([, node]) => Math.hypot(node.x - x, node.y - y) < 15);
    return candidates.length === 1 ? candidates[0][0] : null;
}

const arrows = arrowPlacements.map(arrow => {
    const { sprite, ...fields } = arrow;
    const angle = arrow.rotation * Math.PI / 180;
    const length = spriteWidths.get(sprite) * arrow.scale;
    const end = {
        x: Number((arrow.x + length * Math.cos(angle)).toFixed(3)),
        y: Number((arrow.y - length * Math.sin(angle)).toFixed(3))
    };
    const from = nodeAt(arrow.x, arrow.y);
    const candidate = nodeAt(end.x, end.y);
    const to = candidate !== from ? candidate : null;
    if (from && to) {
        const key = arrow.requirement === 'maxLevel' ? 'needsMaxLevel' : 'needsAnyLevel';
        const prerequisites = nodes[to][key];
        if (!prerequisites.includes(from)) prerequisites.push(from);
    }
    return { ...fields, end, from, to };
});

if (!nodes.o_skill_hammock || !nodes.o_skill_submarine || arrows.length === 0) {
    throw new Error('The parsed room does not match the expected native skill layout.');
}

const layout = {
    room: roomName,
    width: uint(room + 8),
    height: uint(room + 12),
    sourceSha256: createHash('sha256').update(bytes).digest('hex'),
    nodeCount: Object.keys(nodes).length,
    arrowCount: arrows.length,
    unresolvedArrowCount: arrows.filter(arrow => !arrow.from || !arrow.to).length,
    nodes,
    arrows
};
const json = JSON.stringify(layout, null, 2) + '\n';
if (output) writeFileSync(output, json);
else process.stdout.write(json);
