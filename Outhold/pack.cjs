const fs = require("node:fs");
const { zstdDecompressSync } = require("node:zlib");
const { createHash } = require("node:crypto");
const [action, source, ...args] = process.argv.slice(2);
if (!source || !["list", "settings", "ids", "build"].includes(action) ||
    (action === "build" && args.length !== 2) ||
    (action === "list" && args.length !== 1) ||
    (action === "ids" && args.length < 1)) {
  console.error("Usage: node pack.cjs build <stock.pck> <output.pck> <script.gd>");
  console.error("       node pack.cjs list <stock.pck> <pattern>");
  console.error("       node pack.cjs settings <stock.pck>");
  console.error("       node pack.cjs ids <stock.pck> <entry>...");
  process.exit(2);
}
const pack = fs.readFileSync(source);
if (action === "build") {
  const stockHash = "74f975c009f37c6c7424961a9074a2ed1da65912a174d5dc6c89a1dcfd79adda";
  if (createHash("sha256").update(pack).digest("hex") !== stockHash) {
    throw new Error("The input PCK does not match the supported stock Outhold build.");
  }
}
const base = Number(pack.readBigUInt64LE(24));
const directory = Number(pack.readBigUInt64LE(32));
let cursor = directory + 4;
const entries = new Map();
for (let index = 0; index < pack.readUInt32LE(directory); index++) {
  const length = pack.readUInt32LE(cursor);
  const name = pack.toString("utf8", cursor + 4, cursor + 4 + length).replace(/\0+$/, "");
  const info = cursor + 4 + length;
  const start = base + Number(pack.readBigUInt64LE(info));
  const size = Number(pack.readBigUInt64LE(info + 8));
  cursor = info + 36;
  entries.set(name, { start, size, entry: pack.subarray(info, cursor) });
}
function content(name) {
  const { start, size } = entries.get(name);
  return pack.subarray(start, start + size);
}
function settings() {
  const project = content("project.binary");
  let offset = 8;
  const rows = new Map();
  for (let index = 0; index < project.readUInt32LE(4); index++) {
    const keyLength = project.readUInt32LE(offset);
    offset += 4;
    const key = project.toString("utf8", offset, offset + keyLength);
    offset += keyLength;
    const valueLength = project.readUInt32LE(offset);
    offset += 4;
    rows.set(key, project.subarray(offset, offset + valueLength));
    offset += valueLength;
  }
  return rows;
}
function u32(value) {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32LE(value);
  return bytes;
}
function godotString(value) {
  const text = Buffer.from(value);
  return Buffer.concat([u32(4), u32(text.length), text, Buffer.alloc((4 - text.length % 4) % 4)]);
}
function writePack(destination, script) {
  const project = settings();
  project.set("autoload/CampaignCli", godotString("*res://campaign_cli.gd"));
  const config = [Buffer.from("ECFG"), u32(project.size)];
  for (const [key, value] of project) {
    const name = Buffer.from(key);
    config.push(u32(name.length), name, u32(value.length), value);
  }
  const payload = [pack.subarray(0, directory)];
  let position = directory;
  const updates = new Map([
    ["project.binary", Buffer.concat(config)],
    ["campaign_cli.gd", fs.readFileSync(script)],
  ]);
  for (const [name, bytes] of updates) {
    const padding = Buffer.alloc((16 - position % 16) % 16);
    position += padding.length;
    payload.push(padding, bytes);
    const entry = Buffer.alloc(36);
    entry.writeBigUInt64LE(BigInt(position - base));
    entry.writeBigUInt64LE(BigInt(bytes.length), 8);
    createHash("md5").update(bytes).digest().copy(entry, 16);
    entries.set(name, { entry });
    position += bytes.length;
  }
  const padding = Buffer.alloc((16 - position % 16) % 16);
  payload.push(padding, u32(entries.size));
  const header = Buffer.from(payload[0]);
  header.writeBigUInt64LE(BigInt(position + padding.length), 32);
  payload[0] = header;
  for (const [name, { entry }] of entries) {
    const encoded = Buffer.from(name);
    const paddedLength = Math.ceil(encoded.length / 4) * 4;
    payload.push(u32(paddedLength), encoded, Buffer.alloc(paddedLength - encoded.length), entry);
  }
  fs.writeFileSync(destination, Buffer.concat(payload), { flag: "wx" });
}
function identifiers(name) {
  const script = content(name);
  const bytes = script.readUInt32LE(8) ? zstdDecompressSync(script.subarray(12)) : script.subarray(12);
  let offset = 16;
  const names = [];
  for (let index = 0; index < bytes.readUInt32LE(0); index++) {
    const length = bytes.readUInt32LE(offset);
    offset += 4;
    let identifier = "";
    for (let character = 0; character < length; character++, offset += 4) {
      identifier += String.fromCodePoint((bytes.readUInt32LE(offset) ^ 0xb6b6b6b6) >>> 0);
    }
    names.push(identifier);
  }
  console.log(name, names.join(" "));
  console.log([...bytes.subarray(offset).toString().matchAll(/[\x20-\x7e]{5,}/g)].map(m => m[0]).slice(0, 70).join(" | "));
}
if (action === "list") for (const name of entries.keys()) { if (new RegExp(args[0], "i").test(name)) console.log(name); }
if (action === "settings") for (const [name, value] of settings()) {
  if (/autoload|disable_project|main_scene|config\/name|user_dir/.test(name)) console.log(name, value.subarray(8).toString().replace(/\0/g, ""));
}
if (action === "ids") for (const name of args) identifiers(name);
if (action === "build") writePack(...args);
