###############################################################################
# Veilborn Game Server — Dockerfile
# 
# Builds a minimal container running the Godot 4 headless server.
# Base: Ubuntu 22.04 (Godot's officially supported Linux platform)
#
# Build:
#   docker build -t veilborn-server:latest .
#
# Run locally:
#   docker run --rm -p 7777:7777/udp \
#     -e VEILBORN_PORT=7777 \
#     -e VEILBORN_MAX_PLAYERS=64 \
#     -e VEILBORN_WORLD_SEED=42069 \
#     veilborn-server:latest
###############################################################################

FROM ubuntu:22.04 AS base

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    libfontconfig1 \
    libfreetype6 \
    libx11-6 \
    libxcursor1 \
    libxinerama1 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxxf86vm1 \
    libudev1 \
    libpulse0 \
    libgles2 \
    libvulkan1 \
    curl \
    unzip \
    awscli \
    postgresql-client \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

###############################################################################
# BUILD STAGE — Download and verify Godot headless binary
###############################################################################
FROM base AS builder

ARG GODOT_VERSION=4.3
ARG GODOT_RELEASE=stable
ARG GODOT_FILENAME="Godot_v${GODOT_VERSION}-${GODOT_RELEASE}_linux.x86_64"

WORKDIR /build

# Download Godot headless binary
RUN curl -fsSL \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-${GODOT_RELEASE}/${GODOT_FILENAME}.zip" \
    -o godot.zip \
  && unzip godot.zip \
  && mv "$GODOT_FILENAME" /usr/local/bin/godot \
  && chmod +x /usr/local/bin/godot \
  && rm godot.zip

# Verify binary works
RUN godot --version

# Export templates (needed for exported projects)
ARG GODOT_TEMPLATES="Godot_v${GODOT_VERSION}-${GODOT_RELEASE}_export_templates.tpz"
RUN curl -fsSL \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-${GODOT_RELEASE}/${GODOT_TEMPLATES}" \
    -o templates.tpz \
  && mkdir -p ~/.local/share/godot/export_templates/${GODOT_VERSION}.${GODOT_RELEASE} \
  && unzip templates.tpz \
  && mv templates/* ~/.local/share/godot/export_templates/${GODOT_VERSION}.${GODOT_RELEASE}/ \
  && rm -rf templates.tpz templates

###############################################################################
# RUNTIME STAGE
###############################################################################
FROM base AS runtime

# Copy Godot binary from builder
COPY --from=builder /usr/local/bin/godot /usr/local/bin/godot

# Create non-root user for the game server process
RUN groupadd -r veilborn && useradd -r -g veilborn -d /app -s /bin/bash veilborn

# Create application directories
RUN mkdir -p \
      /app/server \
      /data/chunks \
      /data/mods \
      /data/saves \
      /logs \
    && chown -R veilborn:veilborn /app /data /logs

WORKDIR /app

# Copy exported game server project
# (run 'godot --export-release "Linux/X11" server/veilborn_server.x86_64' first)
COPY --chown=veilborn:veilborn ./export/veilborn_server.x86_64 /app/server/veilborn_server
COPY --chown=veilborn:veilborn ./export/veilborn_server.pck    /app/server/veilborn_server.pck
RUN chmod +x /app/server/veilborn_server

# Copy server entrypoint script
COPY --chown=veilborn:veilborn scripts/docker_entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Copy DB migration scripts
COPY --chown=veilborn:veilborn server/migrations/ /app/migrations/

# Copy default server config
COPY --chown=veilborn:veilborn server/config/server_defaults.json /app/config/defaults.json

# Volumes for persistent data
VOLUME ["/data", "/logs"]

# Health check — game server exposes HTTP health endpoint on 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

# Expose game port (UDP) and health/admin port (TCP)
EXPOSE 7777/udp
EXPOSE 8080/tcp

USER veilborn

ENTRYPOINT ["/app/entrypoint.sh"]
