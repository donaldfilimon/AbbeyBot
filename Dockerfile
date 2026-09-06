# syntax=docker/dockerfile:1.7

# Keep this Bun version identical to the Abbey CI setup-bun version. Quasar
# installs and launches approved Next.js workspaces with this runtime.
FROM oven/bun:1.3.14-slim AS bun

FROM oven/bun:1.3.14-slim AS web-build
WORKDIR /web-build
COPY web/package.json web/bun.lock ./
RUN bun install --frozen-lockfile
COPY web ./
RUN bun run build

# Package.swift requires Swift 6.4. The same pinned image is used by Abbey CI.
FROM swiftlang/swift:nightly-6.4.x-bookworm AS build
WORKDIR /build
ENV ABBEY_PACKAGE_ROLE=server
COPY Package.swift Package.resolved* ./
COPY Contracts ./Contracts
COPY Sources ./Sources
COPY --from=web-build /Sources/AbbeyServer/Resources/Public ./Sources/AbbeyServer/Resources/Public
RUN swift package resolve
RUN swift build -c release --product AbbeyBot
RUN test -x .build/release/AbbeyBot \
    && test -d .build/release/AbbeyBot_AbbeyCore.resources \
    && test -d .build/release/AbbeyBot_AbbeyQuasarKit.resources \
    && test -d .build/release/AbbeyBot_AbbeyServer.resources

FROM debian:bookworm-slim AS runtime
ARG ABBEY_VCS_REF=unknown
LABEL org.opencontainers.image.source="https://github.com/donaldfilimon/AbbeyBot" \
      org.opencontainers.image.revision="${ABBEY_VCS_REF}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libatomic1 \
    libcurl4 \
    libsqlite3-0 \
    libssl3 \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

# The executable dynamically links the Swift runtime from the pinned builder.
COPY --from=build /usr/lib/swift/linux /usr/lib/swift/linux
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN mkdir -p /usr/local/bun-node-fallback-bin \
    && ln -s /usr/local/bin/bun /usr/local/bin/bunx \
    && ln -s /usr/local/bin/bun /usr/local/bun-node-fallback-bin/node

WORKDIR /app
COPY --from=build /build/.build/release/AbbeyBot /app/AbbeyBot
COPY --from=build /build/.build/release/AbbeyBot_AbbeyCore.resources /app/AbbeyBot_AbbeyCore.resources
COPY --from=build /build/.build/release/AbbeyBot_AbbeyQuasarKit.resources /app/AbbeyBot_AbbeyQuasarKit.resources
COPY --from=build /build/.build/release/AbbeyBot_AbbeyServer.resources /app/AbbeyBot_AbbeyServer.resources

RUN groupadd --system --gid 10001 abbey \
    && useradd --system --uid 10001 --gid abbey --home-dir /var/lib/abbey --create-home abbey \
    && install -d -o abbey -g abbey /var/lib/abbey/quasar /var/cache/abbey/bun

ENV ABBEY_PACKAGE_ROLE=server \
    BUN_INSTALL_BIN=/var/lib/abbey/.bun/bin \
    BUN_INSTALL_CACHE_DIR=/var/cache/abbey/bun \
    HOME=/var/lib/abbey \
    HTTP_HOSTNAME=0.0.0.0 \
    HTTP_PORT=8080 \
    LD_LIBRARY_PATH=/usr/lib/swift/linux \
    PATH=/usr/local/bun-node-fallback-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER abbey
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=8 \
    CMD curl --fail --silent --show-error http://127.0.0.1:8080/health >/dev/null || exit 1
ENTRYPOINT ["/app/AbbeyBot"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
