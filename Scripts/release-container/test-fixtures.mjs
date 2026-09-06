import assert from "node:assert/strict";
import { marker, respond } from "./provider.mjs";
import { parseStat } from "./process-groups.mjs";

function request(planner, token = "abbey-release-fixture-token", model = "abbey-release-fixture") {
  return new Request("http://fixture/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify({ model, messages: [{ role: "system", content: `bounded ${planner} planner` }] }),
  });
}
for (const planner of ["read", "mutation"]) {
  const response = await respond(request(planner));
  assert.equal(response.status, 200);
  const plan = JSON.parse((await response.json()).choices[0].message.content);
  if (planner === "read") assert.deepEqual(plan, { paths: ["app/page.tsx"] });
  else {
    assert.equal(plan.operations.length, 1);
    assert.equal(plan.operations[0].path, "app/page.tsx");
    assert(plan.operations[0].content.includes(marker));
  }
}
assert.equal((await respond(request("read", "wrong"))).status, 401);
assert.equal((await respond(request("other"))).status, 400);
assert.equal((await respond(request("read", "abbey-release-fixture-token", "other"))).status, 400);
assert.equal((await respond(new Request("http://fixture/health"))).status, 200);
assert.equal((await respond(new Request("http://fixture/other"))).status, 404);
assert.deepEqual(parseStat("123 (space ) name) Z 1 123 0 0"), { group: 123, state: "Z" });
assert.deepEqual(parseStat("123 (next-server) S 100 111 0 0"), { group: 111, state: "S" });
assert.throws(() => parseStat("bad"));
assert.throws(() => parseStat("123 (bad group) S 1 invalid"));
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: respond });
try {
  const original = request("read");
  const response = await fetch(`http://127.0.0.1:${server.port}/v1/chat/completions`, {
    method: "POST", headers: original.headers, body: await original.text(),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse((await response.json()).choices[0].message.content), { paths: ["app/page.tsx"] });
} finally {
  server.stop(true);
}
console.log("Release provider and process-stat fixture checks passed");
