import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, renameSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const stage = path => fileURLToPath(new URL(path, import.meta.url));
const executable = process.argv[2] ?? stage('../Shelldiver.original.exe');
const layoutPath = process.argv[3] ?? stage('./skill-layout.original.json');
const dumpbin = process.argv[4] ?? stage('../toolchain/msvc/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/dumpbin.exe');
const output = process.argv[5];
const bytes = readFileSync(executable);
const executableSha256 = createHash('sha256').update(bytes).digest('hex');
const supportedSha256 = '62599f01a4ce4b8946fcc38827e6364539e31abbed99b0828112e670b0c3925e';
if (executableSha256 !== supportedSha256) throw new Error('This extractor only supports the verified stock Shelldiver build.');

const layout = JSON.parse(readFileSync(layoutPath, 'utf8'));
const sourceDataSha256 = '4b4f08b6c85fd3852a08bccdbb0d6621cc614225f9f804df6afe79258e8c0506';
if (layout.sourceSha256 !== sourceDataSha256) throw new Error('The static layout does not match this stock build.');

const pe = bytes.readUInt32LE(0x3c);
const imageBase = Number(bytes.readBigUInt64LE(pe + 48));
const sectionStart = pe + 24 + bytes.readUInt16LE(pe + 20);
const sections = Array.from({ length: bytes.readUInt16LE(pe + 6) }, (_, index) => {
    const offset = sectionStart + index * 40;
    return {
        name: bytes.toString('latin1', offset, offset + 8).split('\0')[0],
        address: bytes.readUInt32LE(offset + 12),
        size: bytes.readUInt32LE(offset + 16),
        offset: bytes.readUInt32LE(offset + 20)
    };
});

const [code, data, unwind] = ['.text', '.data', '.pdata'].map(name => sections.find(section => section.name === name));
function fileOffset(address) {
    const rva = address - imageBase;
    const section = sections.find(s => s.address <= rva && rva < s.address + s.size);
    return section ? section.offset + rva - section.address : null;
}

function nativeString(address) {
    const offset = fileOffset(address);
    if (offset === null) return null;
    const end = bytes.indexOf(0, offset);
    return end >= offset && end - offset < 250 ? bytes.toString('latin1', offset, end) : null;
}

function staticValue(address) {
    const offset = fileOffset(address);
    if (offset === null || offset + 16 > bytes.length) return undefined;
    const kind = bytes.readUInt32LE(offset + 12);
    if (kind === 0) {
        const value = bytes.readDoubleLE(offset);
        return Number.isFinite(value) ? value : undefined;
    }
    if (kind === 7) return bytes.readInt32LE(offset);
    if (kind === 10) {
        const value = Number(bytes.readBigInt64LE(offset));
        return Number.isSafeInteger(value) ? value : undefined;
    }
    return undefined;
}

const functions = new Map();
for (let offset = unwind.offset; offset + 12 <= unwind.offset + unwind.size; offset += 12) {
    const begin = bytes.readUInt32LE(offset);
    const end = bytes.readUInt32LE(offset + 4);
    if (begin && end > begin) functions.set(imageBase + begin, imageBase + end);
}

const symbols = new Map();
for (let offset = data.offset; offset + 16 <= data.offset + data.size; offset += 8) {
    const address = Number(bytes.readBigUInt64LE(offset + 8));
    const rva = address - imageBase;
    if (rva < code.address || rva >= code.address + code.size) continue;
    const name = nativeString(Number(bytes.readBigUInt64LE(offset)));
    if (name?.startsWith('gml_') && functions.has(address)) symbols.set(name, address);
}

function disassemble(begin) {
    const end = functions.get(begin);
    const range = '/range:0x' + begin.toString(16) + ',0x' + end.toString(16);
    const output = execFileSync(dumpbin, ['/nologo', '/disasm:bytes', range, executable], { encoding: 'utf8' });
    return output.split(/\r?\n/).flatMap(line => {
        const match = /^\s+([0-9A-F]{16}):\s+[0-9A-F]{2}(?: [0-9A-F]{2})*\s{2,}([a-z][a-z0-9]*)(?:\s+(.*))?$/i.exec(line);
        if (!match) return [];
        return [{ address: parseInt(match[1], 16), op: match[2], operands: match[3]?.split(',') ?? [] }];
    });
}

const routines = {
    array: imageBase + 0x4e66f0,
    copy: imageBase + 0x164f0,
    copyLiteral: imageBase + 0x16a00,
    createMethod: imageBase + 0x4cc2c0,
    invoke: imageBase + 0x4cb210,
    clear: imageBase + 0x16300
};

const fields = { currency: '0000000140DA4AD0h', prices: '0000000140DA39C0h' };
const currencyNames = new Map([
    [1, 'shells'], [3, 'scrap'], [4, 'crystals'], [5, 'mushrooms'], [6, 'obsidian'], [7, 'lifeVials']
]);

function immediate(text) {
    if (typeof text !== 'string') return undefined;
    if (/^[0-9]+$/.test(text)) return Number(text);
    if (/^[0-9a-f]+h$/i.test(text)) return Number.parseInt(text, 16);
    return undefined;
}

function addressOperand(text) {
    return /^[0-9A-F]{16}$/i.test(text ?? '') ? Number.parseInt(text, 16) : null;
}

function register(text) {
    const short = { eax: 'rax', ebx: 'rbx', ecx: 'rcx', edx: 'rdx', esi: 'rsi', edi: 'rdi', ebp: 'rbp', esp: 'rsp' };
    if (Object.hasOwn(short, text)) return short[text];
    return /^r(?:ax|bx|cx|dx|si|di|bp|sp|[89]|1[0-5])d?$/.test(text ?? '') ? text.replace(/d$/, '') : null;
}

function memoryOperand(text) {
    const match = /\[([^\]]+)\]$/.exec(text ?? '');
    if (!match) return null;
    const address = immediate(match[1]);
    if (address !== undefined) return { kind: 'address', address };
    const relative = /^(r[0-9a-z]+)(?:([+-])([0-9A-Fa-f]+h?))?$/.exec(match[1]);
    if (!relative) return null;
    return {
        kind: 'local', base: relative[1],
        offset: relative[3] ? (relative[2] === '-' ? -1 : 1) * immediate(relative[3]) : 0
    };
}

function argumentIndex(instructions, field) {
    const start = instructions.findIndex(i => i.operands[1]?.includes(fields[field]));
    if (start < 0) return null;

    for (let index = start + 1; index < Math.min(start + 24, instructions.length - 1); ++index) {
        if (instructions[index].op !== 'jle') continue;
        const read = instructions[index + 1];
        const source = memoryOperand(read.operands[1]);
        if (read.op === 'mov' && read.operands[1]?.startsWith('qword ptr ') &&
            source?.kind === 'local' && !['rsp', 'rbp'].includes(source.base) &&
            Number.isInteger(source.offset / 8) && source.offset >= 0) {
            return source.offset / 8;
        }
    }
    return null;
}

function constructorArguments(instructions, constructor) {
    const registers = new Map();
    const memory = new Map();
    const key = location => location.base + ':' + location.offset;
    const load = location => location?.kind === 'local' ? memory.get(key(location)) : undefined;
    const store = (location, value) => {
        if (location?.kind === 'local') memory.set(key(location), value);
    };
    const dereference = pointer => pointer?.kind === 'address' ? staticValue(pointer.address) : load(pointer);
    const stack = offset => ({ kind: 'local', base: 'rsp', offset });

    for (const instruction of instructions) {
        const { op, operands } = instruction;
        const [destination, source] = operands;
        const target = register(destination);
        if (op === 'lea' && target) {
            registers.set(target, memoryOperand(source));
        } else if (op === 'mov') {
            const sourceRegister = register(source);
            const value = sourceRegister ? registers.get(sourceRegister) : immediate(source) ?? load(memoryOperand(source));
            if (target) registers.set(target, value);
            else store(memoryOperand(destination), value);
        } else if (op === 'xor' && target && destination === source) {
            registers.set(target, 0);
        } else if (op === 'call') {
            const called = addressOperand(destination);
            const targetPointer = registers.get('rcx');
            const inputPointer = registers.get('rdx');
            const r8 = registers.get('r8');
            const r9 = registers.get('r9');
            let result;

            if (called === routines.array && Number.isInteger(r8) && r8 > 0 && r8 <= 64) {
                const entries = [r9, ...Array.from({ length: r8 - 1 }, (_, index) => load(stack(32 + index * 8)))];
                store(targetPointer, entries.map(dereference));
                result = targetPointer;
            } else if (called === routines.copy || called === routines.copyLiteral) {
                store(targetPointer, dereference(inputPointer));
            } else if (called === routines.createMethod) {
                store(targetPointer, { method: inputPointer?.address });
            } else if (called === routines.clear) {
                store(targetPointer, undefined);
            } else if (called === routines.invoke && Number.isInteger(r9) && r9 > 1 && r9 <= 16) {
                const start = load(stack(40));
                if (start?.kind === 'local' && dereference(load(start))?.method === constructor) {
                    return {
                        address: instruction.address,
                        values: Array.from({ length: r9 - 1 }, (_, index) =>
                            dereference(load({ ...start, offset: start.offset + (index + 1) * 8 })))
                    };
                }
            }

            if (called === null && /^qword ptr \[r[0-9a-z]+\+(8|10h)\]$/.test(destination ?? '')) {
                // Generated instance-member lookups yield a stable RValue pointer.
                result = { kind: 'local', base: 'member', offset: instruction.address };
            }
            for (const name of ['rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11']) registers.delete(name);
            if (result) registers.set('rax', result);
        } else if (target && !['test', 'cmp', 'push'].includes(op)) {
            registers.delete(target);
        }
    }
    return null;
}

function isPriceList(prices) {
    return Array.isArray(prices) && prices.length > 0 &&
        prices.every(price => typeof price === 'number' && Number.isFinite(price) && price >= 0);
}

function isCurrencyCode(value) {
    return Number.isInteger(value) && currencyNames.has(value);
}

function analyzeNode(id) {
    const event = 'gml_Object_' + id + '_Create_0';
    const begin = symbols.get(event);
    const candidates = [...symbols].filter(([name]) => {
        const constructor = /^gml_Script____struct___\d+@([^@]+)$/.exec(name);
        return constructor?.[1] === event;
    });
    if (!begin || candidates.length !== 1) return { status: 'unsupported', reason: 'constructor not uniquely identified' };

    const [, constructor] = candidates[0];
    const createCode = disassemble(begin);
    const structCode = disassemble(constructor);
    const currencyIndex = argumentIndex(structCode, 'currency');
    const pricesIndex = argumentIndex(structCode, 'prices');
    const applied = constructorArguments(createCode, constructor);
    const evidence = { createRva: begin - imageBase, structRva: constructor - imageBase };
    if (currencyIndex === null || pricesIndex === null || !applied) {
        return { status: 'unsupported', reason: 'constructor arguments could not be proven', evidence };
    }

    const prices = applied.values[pricesIndex];
    const currency = applied.values[currencyIndex];
    const currencyByRank = Array.isArray(currency) ? currency : isPriceList(prices) ? prices.map(() => currency) : null;
    if (!isPriceList(prices) || !currencyByRank || currencyByRank.length !== prices.length ||
        !currencyByRank.every(isCurrencyCode)) {
        return { status: 'unsupported', reason: 'native prices or currencies are not a complete constant array', evidence };
    }

    const laterWrites = createCode.filter(instruction => instruction.address > applied.address &&
        Object.values(fields).some(field => instruction.operands[1]?.includes(field)));
    const ranks = prices.map((price, index) => ({
        rank: index + 1,
        price,
        currencyCode: currencyByRank[index],
        currency: currencyNames.get(currencyByRank[index])
    }));
    if (laterWrites.length) {
        return {
            status: 'variant', reason: 'constructor has later price or currency references',
            baseRanks: ranks, evidence
        };
    }
    return { status: 'constant', maxRank: prices.length, ranks, evidence };
}

const nodes = {};
for (const [id, position] of Object.entries(layout.nodes)) nodes[id] = { ...position, ...analyzeNode(id) };
const counts = {};
for (const node of Object.values(nodes)) counts[node.status] = (counts[node.status] ?? 0) + 1;
const catalog = { executableSha256, sourceDataSha256, counts, nodes };
const json = JSON.stringify(catalog, null, 2) + '\n';
if (output) {
    const pending = output + '.' + process.pid + '.pending';
    writeFileSync(pending, json, { flag: 'wx' });
    renameSync(pending, output);
}
else process.stdout.write(json);
