# Build Stage
FROM alpine:latest AS builder

# Install build dependencies
# sqlite-dev: required for linking against sqlite3
# build-base: standard build tools (gcc, make, etc.), useful for C dependencies if any
# curl, tar, xz: for downloading Zig
# jq: for parsing Zig download index
# gcompat: to run official Zig binaries (glibc) on Alpine
RUN apk add --no-cache \
    sqlite-dev \
    build-base \
    curl \
    tar \
    xz \
    jq \
    gcompat

# Install Zig Master (Latest Nightly)
WORKDIR /usr/local/bin
RUN curl -s https://ziglang.org/download/index.json | jq -r '.master."x86_64-linux".tarball' > zig_url \
    && echo "Downloading Zig from: $(cat zig_url)" \
    && curl -L $(cat zig_url) | tar -xJ \
    && mv zig-linux-x86_64-*/* . \
    && rm -rf zig-linux-x86_64-* \
    && rm zig_url

WORKDIR /app

# Copy build definition files first to leverage caching
COPY build.zig build.zig.zon ./

# Copy source code
COPY src/ src/
COPY include/ include/
COPY README.md ./

# Build the project
# -Doptimize=ReleaseFast: Enable optimizations
# -Dtarget=x86_64-linux-musl: Explicitly target Alpine (musl)
RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl

# Runtime Stage
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    sqlite-libs \
    libstdc++

WORKDIR /app

# Copy artifacts from builder
COPY --from=builder /app/zig-out/bin/axion /usr/local/bin/axion
COPY --from=builder /app/zig-out/bin/axion_shell /usr/local/bin/axion_shell
COPY --from=builder /app/zig-out/lib/libaxion.so /usr/local/lib/libaxion.so

# Create a directory for data persistence
RUN mkdir -p /data
WORKDIR /data

# Expose standard volume
VOLUME ["/data"]

# Default entrypoint is the shell
ENTRYPOINT ["axion_shell"]
CMD ["--help"]
