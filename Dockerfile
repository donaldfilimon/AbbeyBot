# syntax=docker/dockerfile:1.7

# Keep this Bun version identical to the Abbey CI setup-bun version and the
# release gate's assertion. Quasar installs and launches approved Next.js
# workspaces with this runtime, and the packaged next-site template's bun.lock
# has been lockfileVersion 2 since it was committed -- which 1.3.14 cannot parse,
# so every scaffold died on "Unknown lockfile version" under --frozen-lockfile.
# Bumping the reader rather than regenerating the lockfile keeps the reviewed
# dependency resolution byte-identical.
FROM oven/bun:1.4.2-slim AS bun

FROM oven/bun:1.4.2-slim AS web-build
WORKDIR /web-build
COPY web/package.json web/bun.lock ./
RUN bun install --frozen-lockfile
COPY web ./
RUN bun run build

# Package.swift requires Swift 6.4. The same pinned image is used by Abbey CI.
FROM swiftlang/swift:nightly-6.4.x-bookworm AS build
WORKDIR /build
ENV ABBEY_PACKAGE_ROLE=server
COPY Scripts/release-container/stage-products.sh Scripts/release-container/check-swift-resources.sh \
     Scripts/release-container/stage-swift-runtime.sh /release-tools/
COPY Scripts/release-container/swift-resource-fixture /release-tools/swift-resource-fixture
RUN bash /release-tools/check-swift-resources.sh
COPY Package.swift Package.resolved* ./
COPY Contracts ./Contracts
COPY Sources ./Sources
COPY Tests ./Tests
COPY --from=web-build /Sources/AbbeyServer/Resources/Public ./Sources/AbbeyServer/Resources/Public
RUN swift package resolve
RUN swift build -c release --product AbbeyBot
RUN bash /release-tools/stage-products.sh \
    "$(swift build -c release --product AbbeyBot --show-bin-path)" /stage AbbeyBot \
    AbbeyBot_AbbeyCore AbbeyBot_AbbeyQuasarKit AbbeyBot_AbbeyServer
# Discover the runtime beside the binary rather than hardcoding a toolchain
# path: `/usr/lib/swift/linux` vanished under swiftlang/swift nightly 6.4.x and
# the hardcoded COPY below failed with an opaque "not found" after a 32-minute
# build. See Scripts/release-container/stage-swift-runtime.sh.
RUN bash /release-tools/stage-swift-runtime.sh /stage/AbbeyBot /stage-runtime

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
# Staged at a fixed path in the build stage so this COPY does not depend on the
# toolchain image's own layout; LD_LIBRARY_PATH below points at the destination.
COPY --from=build /stage-runtime/ /usr/lib/swift/linux/
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN mkdir -p /usr/local/bun-node-fallback-bin \
    && ln -s /usr/local/bin/bun /usr/local/bin/bunx \
    && ln -s /usr/local/bin/bun /usr/local/bun-node-fallback-bin/node

WORKDIR /app
COPY --from=build /stage/ /app/
# QuasarScaffolder materializes next-site out of this bundle into a site
# workspace with FileManager.copyItem. Linux Foundation preserves ownership on
# copy, so as uid 10001 against root-owned sources that chown is EPERM and every
# POST /api/sites failed with a redacted 500. Darwin does not chown, which is why
# it reproduced only in the container. Hand the runtime user its own resource
# bundles; the executable stays root-owned so a writable rootfs cannot be used to
# overwrite it.
RUN find /app -maxdepth 1 \( -name '*.bundle' -o -name '*.resources' \) \
    -exec chown -R 10001:10001 {} +

RUN groupadd --system --gid 10001 abbey \
    && useradd --system --uid 10001 --gid abbey --home-dir /var/lib/abbey --create-home abbey \
    && install -d -o abbey -g abbey /var/lib/abbey/quasar /var/lib/abbey/.abbey /var/cache/abbey/bun

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
