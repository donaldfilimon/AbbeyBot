# syntax=docker/dockerfile:1
# Build with official Swift 6.4 bookworm image (Linux) — must match Package.swift's
# swift-tools-version: an older toolchain's SwiftPM cannot parse a newer manifest.
# Leaf resources ship via SPM bundle.

FROM swift:6.4-bookworm AS build
WORKDIR /build
COPY Package.swift Package.resolved* ./
COPY Sources ./Sources
COPY Tests ./Tests
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
# SPM resource bundle name: <product>_<target>.resources
COPY --from=build /build/.build/release/AbbeyServer_AbbeyServer.resources /app/AbbeyServer_AbbeyServer.resources
ENV HTTP_HOSTNAME=0.0.0.0
ENV HTTP_PORT=8080
EXPOSE 8080
CMD ["/app/AbbeyServer", "serve", "--hostname", "0.0.0.0", "--port", "8080"]
