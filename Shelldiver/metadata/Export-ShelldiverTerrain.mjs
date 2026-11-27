import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const [, , input, output] = process.argv;
if (!input || !output || !output.endsWith('.json') || resolve(input) === resolve(output)) {
    throw new Error('Usage: node Export-ShelldiverTerrain.mjs <stock data.win> <output.json>');
}

const bytes = readFileSync(input);
const sourceSha256 = createHash('sha256').update(bytes).digest('hex');
const supportedData = '4b4f08b6c85fd3852a08bccdbb0d6621cc614225f9f804df6afe79258e8c0506';
if (sourceSha256 !== supportedData) {
    throw new Error('The data.win SHA-256 does not match the supported original Shelldiver build.');
}

const u32 = offset => bytes.readUInt32LE(offset);

function pointerList(offset) {
    const count = u32(offset);
    const end = offset + 4 + count * 4;
    if (end > bytes.length) throw new Error('Truncated GameMaker pointer list.');
    return Array.from({ length: count }, (_, index) => u32(offset + 4 + index * 4));
}

function stringAt(offset) {
    const end = offset + u32(offset - 4);
    if (end > bytes.length) throw new Error('Truncated GameMaker resource name.');
    return bytes.toString('utf8', offset, end);
}

function readForm() {
    if (bytes.toString('ascii', 0, 4) !== 'FORM' || u32(4) + 8 !== bytes.length) {
        throw new Error('Expected a complete GameMaker FORM file.');
    }
    const chunks = new Map();
    for (let offset = 8; offset < bytes.length;) {
        const name = bytes.toString('ascii', offset, offset + 4);
        const content = offset + 8;
        const next = content + u32(offset + 4);
        if (next > bytes.length || chunks.has(name)) throw new Error('Unexpected GameMaker chunk bounds.');
        chunks.set(name, content);
        offset = next;
    }
    return chunks;
}

function readTileOccupancy(offset, width, height) {
    const count = width * height;
    const occupancy = [];
    while (occupancy.length < count) {
        const opcode = bytes.readUInt8(offset++);
        const repeat = opcode >= 128;
        const runLength = repeat ? (opcode & 0x7f) + 1 : opcode;
        if (!runLength || occupancy.length + runLength > count) {
            throw new Error('Tilemap RLE run extends outside the expected grid.');
        }
        if (repeat) {
            const glyph = u32(offset) === 0 ? '.' : '#';
            for (let i = 0; i < runLength; ++i) occupancy.push(glyph);
            offset += 4;
        } else {
            for (let i = 0; i < runLength; ++i, offset += 4) {
                occupancy.push(u32(offset) === 0 ? '.' : '#');
            }
        }
    }
    return Array.from({ length: height }, (_, y) => occupancy.slice(y * width, (y + 1) * width).join(''));
}

function readTerrain(room, backgrounds) {
    // The pinned build uses the newer ROOM header with instance creation order before the layer table.
    const layers = pointerList(u32(room + 92));
    const matches = layers.filter(offset => stringAt(u32(offset)) === 'tl_main');
    if (matches.length !== 1) throw new Error('Expected one tl_main layer in this room.');
    const layer = matches[0];
    if (u32(layer + 8) !== 4 || u32(layer + 16) !== 0 || u32(layer + 20) !== 0 || u32(layer + 44) !== 0) {
        throw new Error('Expected an unshifted tile layer with an empty effect property list.');
    }
    const background = backgrounds[u32(layer + 48)];
    if (background === undefined) throw new Error('Missing native terrain tileset.');
    const tileWidth = u32(background + 24);
    const tileHeight = u32(background + 28);
    const columns = u32(layer + 52);
    const rows = u32(layer + 56);
    const width = u32(room + 8);
    const height = u32(room + 12);
    if (tileWidth !== 16 || tileHeight !== 16 || !columns || !rows ||
        columns * tileWidth !== width || rows * tileHeight !== height) {
        throw new Error('Unexpected native terrain dimensions.');
    }
    return { width, height, tileWidth, tileHeight, rows: readTileOccupancy(layer + 60, columns, rows) };
}

const chunks = readForm();
const roomPointers = new Map(pointerList(chunks.get('ROOM')).map(offset => [stringAt(u32(offset)), offset]));
const backgrounds = pointerList(chunks.get('BGND'));
const rooms = {};
for (const biome of ['shallows', 'glacial', 'swamp', 'magma']) {
    for (const stage of ['01', '02', '03']) {
        const roomName = 'rm_ocean_' + biome + '_' + stage;
        if (!roomPointers.has(roomName)) throw new Error('Missing expected room ' + roomName);
        rooms[roomName] = readTerrain(roomPointers.get(roomName), backgrounds);
    }
}
writeFileSync(output, JSON.stringify({ schemaVersion: 1, sourceSha256, layer: 'tl_main', rooms }) + '\n');
