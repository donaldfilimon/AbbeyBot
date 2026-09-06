import { readFileSync, readdirSync, readlinkSync } from "node:fs";

export function parseStat(text) {
  const close = text.lastIndexOf(")");
  if (close < 0) throw new Error("invalid proc stat");
  const fields = text.slice(close + 1).trim().split(/\s+/);
  const group = Number(fields[2]);
  if (!Number.isInteger(group) || group < 1) throw new Error("invalid proc group");
  return { group, state: fields[0] };
}

function inventory() {
  const rows = [];
  for (const pid of readdirSync("/proc").filter((name) => /^\d+$/.test(name))) {
    let stat;
    try { stat = readFileSync(`/proc/${pid}/stat`, "utf8"); }
    catch (error) { if (error.code === "ENOENT" || error.code === "ESRCH") continue; throw error; }
    let cwd = null;
    // Zombies lose cwd; they must still remain in the group-absence check.
    try { cwd = readlinkSync(`/proc/${pid}/cwd`); }
    catch (error) { if (!["ENOENT", "ESRCH", "EACCES"].includes(error.code)) throw error; }
    rows.push({ pid: Number(pid), cwd, ...parseStat(stat) });
  }
  return rows;
}

if (import.meta.main) {
  const [mode, argument] = process.argv.slice(2);
  const rows = inventory();
  if (mode === "snapshot") {
    if (!argument?.startsWith("/data/quasar/sites/")) throw new Error("unexpected site root");
    const groups = [...new Set(rows.filter((row) => row.cwd === argument).map((row) => row.group))];
    if (!groups.length || groups.includes(parseStat(readFileSync("/proc/self/stat", "utf8")).group)) {
      throw new Error("missing or unsafe preview process-group snapshot");
    }
    console.log(JSON.stringify(groups));
  } else if (mode === "remaining") {
    const groups = JSON.parse(argument);
    if (!Array.isArray(groups) || !groups.length || groups.some((group) => !Number.isInteger(group) || group <= 1)) {
      throw new Error("invalid expected process groups");
    }
    console.log(JSON.stringify(rows.filter((row) => groups.includes(row.group))));
  } else throw new Error("expected snapshot or remaining");
}
