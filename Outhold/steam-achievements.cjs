const fs = require("node:fs");
const path = require("node:path");
const directory = process.argv[2];
if (!directory) {
  console.error("Usage: node steam-achievements.cjs <Steam appcache/stats directory>");
  process.exit(2);
}
function readBinaryKeyValues(file) {
  const data = fs.readFileSync(file);
  let cursor = 0;
  function text() {
    const end = data.indexOf(0, cursor);
    if (end < 0) throw new Error("Unterminated string in Steam cache");
    const value = data.toString("utf8", cursor, end);
    cursor = end + 1;
    return value;
  }
  function entries() {
    const result = Object.create(null);
    while (cursor < data.length) {
      const type = data[cursor++];
      if (type === 8 || type === 11) break;
      const key = text();
      if (type === 0) {
        result[key] = entries();
      } else if (type === 1) {
        result[key] = text();
      } else if ([2, 3, 4, 6].includes(type)) {
        result[key] = type === 3 ? data.readFloatLE(cursor) : data.readUInt32LE(cursor);
        cursor += 4;
      } else if (type === 7 || type === 10) {
        result[key] = data.readBigUInt64LE(cursor);
        cursor += 8;
      } else {
        throw new Error("Unsupported Steam cache field " + type + " at " + cursor);
      }
    }
    return result;
  }
  return entries();
}
const app = "3767740";
const schema = readBinaryKeyValues(path.join(directory, "UserGameStatsSchema_" + app + ".bin"));
const playerFiles = fs.readdirSync(directory).filter(name => new RegExp("^UserGameStats_\\d+_" + app + "\\.bin$").test(name));
if (playerFiles.length !== 1) throw new Error("Expected one local Outhold Steam account cache");
const account = readBinaryKeyValues(path.join(directory, playerFiles[0])).cache;
let count = 0;
let unlocked = 0;
for (const [group, stat] of Object.entries(schema[app].stats)) {
  for (const [bit, definition] of Object.entries(stat.bits || {})) {
    if (!definition.display) continue;
    const done = Boolean((account[group]?.data ?? 0) & (1 << Number(bit)));
    count++;
    if (done) unlocked++;
    console.log(done ? "unlocked" : "locked", definition.name, definition.display.name.english);
  }
}
console.log(unlocked + "/" + count + " in local Steam cache");
