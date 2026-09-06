// This authority is a fixture, not the Swift authorization implementation.
export const sessionCookie = "__Host-abbey-quasar-preview=fixture-session";
export const previewHost = "11111111-1111-1111-1111-111111111111.preview.example.test";
const serviceToken = "abbey-release-gate-internal-token";

export function authority() {
  let ticketUsed = false;
  return async (request) => {
    const url = new URL(request.url);
    if (url.pathname === "/health") return Response.json({ fixture: true });
    if (!url.pathname.startsWith("/internal/")) {
      return Response.json({ authorityFixture: true, headers: Object.fromEntries(request.headers) });
    }
    if (request.headers.get("X-Abbey-Preview-Service-Token") !== serviceToken
        || request.headers.get("X-Abbey-Preview-Host") !== previewHost) {
      return new Response("denied", { status: 401 });
    }
    if (url.pathname === "/internal/quasar/preview/redeem") {
      if (ticketUsed || url.searchParams.get("ticket") !== "fixture-ticket+with/slash") {
        return new Response("invalid ticket", { status: 401 });
      }
      for (const header of ["Authorization", "Cookie", "X-Abbey-Token", "X-Abbey-Quasar-Token"]) {
        if (request.headers.has(header)) return new Response("redeem leaked credentials", { status: 400 });
      }
      ticketUsed = true;
      return new Response(null, { status: 303, headers: {
        "Set-Cookie": `${sessionCookie}; Path=/; Secure; HttpOnly; SameSite=Lax`,
        "Location": `https://${previewHost}/`,
      } });
    }
    if (url.pathname === "/internal/quasar/preview/authorize"
        && request.headers.get("Cookie") === sessionCookie) {
      return new Response(null, { headers: { "X-Quasar-Upstream": "preview-backend:8081" } });
    }
    return new Response("denied", { status: 401 });
  };
}

export const upstream = {
    fetch(request, server) {
      const headers = Object.fromEntries(request.headers);
      if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
        if (server.upgrade(request, { data: { headers } })) return;
        return new Response("upgrade failed", { status: 400 });
      }
      return Response.json({ upstreamFixture: true, headers, path: new URL(request.url).pathname }, {
        headers: { "Set-Cookie": "upstream-must-not-set-cookie=1" },
      });
    },
    websocket: {
      open(socket) { socket.send(JSON.stringify({ upstreamFixture: true, headers: socket.data.headers })); },
      message(socket, message) { socket.send(`echo:${message}`); },
    },
};

if (import.meta.main) {
  Bun.serve({ hostname: "0.0.0.0", port: 8080, fetch: authority() });
  Bun.serve({ ...upstream, hostname: "0.0.0.0", port: 8081 });
}
