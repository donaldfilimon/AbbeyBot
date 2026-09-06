// Deterministic release-gate fixture. No model, external API, or Discord acceptance.
export const marker = "QUASAR_RELEASE_MANAGER_FIXTURE";
export const page = `export default function Home() { return <main><h1>${marker}</h1></main>; }\n`;

export function completion(body) {
  if (body.model !== "abbey-release-fixture") throw new Error("unexpected fixture model");
  const system = body.messages?.find((message) => message.role === "system")?.content ?? "";
  let plan;
  if (system.includes("bounded read planner")) {
    plan = { paths: ["app/page.tsx"] };
  } else if (system.includes("bounded mutation planner")) {
    plan = {
      summary: "Release gate deterministic page",
      idempotencyKey: "release-gate-page-v1",
      operations: [{ type: "write", path: "app/page.tsx", content: page }],
    };
  } else {
    throw new Error("unexpected planner request");
  }
  return { choices: [{ message: { role: "assistant", content: JSON.stringify(plan) } }] };
}

export async function respond(request) {
  const path = new URL(request.url).pathname;
  if (request.method === "GET" && path === "/health") return Response.json({ fixture: true });
  if (request.method !== "POST" || path !== "/v1/chat/completions") {
    return new Response("fixture route not found", { status: 404 });
  }
  if (request.headers.get("Authorization") !== "Bearer abbey-release-fixture-token") {
    return new Response("fixture authorization required", { status: 401 });
  }
  try {
    return Response.json(completion(await request.json()));
  } catch {
    return new Response("fixture rejected unexpected request", { status: 400 });
  }
}

if (import.meta.main) Bun.serve({ hostname: "0.0.0.0", port: 8089, fetch: respond });
