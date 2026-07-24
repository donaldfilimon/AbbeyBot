# syntax=docker/dockerfile:1
# Build with official Swift 6.4 bookworm image (Linux) — must match Package.swift's
# swift-tools-version: an older toolchain's SwiftPM cannot parse a newer manifest.
# Leaf resources ship via SPM bundle. Dashboard SPA is built first so its static
# output exists on disk before the Swift build stage copies Sources/ (SPM's
# .copy("Resources") only picks up files already present at build time).

FROM node:22-bookworm-slim AS web-build
WORKDIR /web-build
COPY web/package.json web/package-lock.json* web/bun.lock* ./
RUN npm install
COPY web ./
# vite.config.ts's outDir ('../Sources/AbbeyServer/Resources/Public', relative to /web-build)
# resolves to /Sources/AbbeyServer/Resources/Public — Vite creates missing parent
# directories itself, no placeholder copy needed.
RUN npm run build

FROM swift:6.4-bookworm AS build
WORKDIR /build
COPY Package.swift Package.resolved* ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY --from=web-build /Sources/AbbeyServer/Resources/Public ./Sources/AbbeyServer/Resources/Public
RUN swift package resolve
RUN swift build -c release --product AbbeyServer

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libssl3 \
    libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/.build/release/AbbeyServer /app/AbbeyServer
# SPM resource bundle name is <package-name>_<target-name>, not <product-name>_<target-name> —
# this package is named "AbbeyBot" (see Package.swift), not "AbbeyServer", even though the
# executable product built here is AbbeyServer. Confirmed by inspecting an actual SwiftPM
# build output this session (this line was wrong before today's changes and would have
# silently shipped a container with no Leaf views / no dashboard assets at all).
COPY --from=build /build/.build/release/AbbeyBot_AbbeyServer.resources /app/AbbeyBot_AbbeyServer.resources
ENV HTTP_HOSTNAME=0.0.0.0
ENV HTTP_PORT=8080
EXPOSE 8080
CMD ["/app/AbbeyServer", "serve", "--hostname", "0.0.0.0", "--port", "8080"]
