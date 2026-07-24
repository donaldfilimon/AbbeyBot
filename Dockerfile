# syntax=docker/dockerfile:1
# Build with Swift 6.4 bookworm (Linux) — must match Package.swift's
# swift-tools-version: an older toolchain's SwiftPM cannot parse a newer manifest.
# library/swift:6.4-* is not on Docker Hub yet; use the swiftlang nightly until it is.
# Leaf resources ship via SPM bundle. Dashboard SPA is built first so its static
# output exists on disk before the Swift build stage copies Sources/ (SPM's
# .copy("Resources") only picks up files already present at build time).

FROM oven/bun:1.2.19-slim AS web-build
WORKDIR /web-build
COPY web/package.json web/bun.lock ./
RUN bun install --frozen-lockfile
COPY web ./
# vite.config.ts's outDir ('../Sources/AbbeyServer/Resources/Public', relative to /web-build)
# resolves to /Sources/AbbeyServer/Resources/Public — Vite creates missing parent
# directories itself, no placeholder copy needed.
RUN bun run build

FROM swiftlang/swift:nightly-6.4.x-bookworm AS build
WORKDIR /build
COPY Package.swift Package.resolved* ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY --from=web-build /Sources/AbbeyServer/Resources/Public ./Sources/AbbeyServer/Resources/Public
RUN swift package resolve
# Server-only graph (no SwiftUI/SwiftData desktop target).
ENV ABBEY_PACKAGE_ROLE=server
RUN swift build -c release --product AbbeyBot

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libssl3 \
    libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/.build/release/AbbeyBot /app/AbbeyBot
# SPM resource bundle name is <package-name>_<target-name> (AbbeyServer library target).
COPY --from=build /build/.build/release/AbbeyBot_AbbeyServer.resources /app/AbbeyBot_AbbeyServer.resources
ENV HTTP_HOSTNAME=0.0.0.0
ENV HTTP_PORT=8080
ENV ABBEY_PACKAGE_ROLE=server
EXPOSE 8080
CMD ["/app/AbbeyBot", "serve", "--hostname", "0.0.0.0", "--port", "8080"]
