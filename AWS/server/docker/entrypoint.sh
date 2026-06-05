#!/bin/bash
###############################################################################
# Veilborn Server — Docker Entrypoint
# Handles: env var validation, DB migration, S3 chunk sync, graceful start
###############################################################################
set -euo pipefail

echo "============================================"
echo " Veilborn Game Server"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# ─── Required environment variables ──────────────────────────────────────────
REQUIRED_VARS=(
  VEILBORN_PORT
  VEILBORN_MAX_PLAYERS
  VEILBORN_WORLD_SEED
)

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Required environment variable '$var' is not set"
    exit 1
  fi
done

# ─── Defaults for optional variables ─────────────────────────────────────────
VEILBORN_REGION="${VEILBORN_REGION:-Unknown Region}"
VEILBORN_LOG_DIR="${VEILBORN_LOG_DIR:-/logs}"
VEILBORN_DATA_DIR="${VEILBORN_DATA_DIR:-/data}"
VEILBORN_ENV="${VEILBORN_ENV:-dev}"
VEILBORN_ADMIN_PORT="${VEILBORN_ADMIN_PORT:-8080}"

echo "Environment  : $VEILBORN_ENV"
echo "Game Port    : $VEILBORN_PORT/udp"
echo "Admin Port   : $VEILBORN_ADMIN_PORT/tcp"
echo "Max Players  : $VEILBORN_MAX_PLAYERS"
echo "World Seed   : $VEILBORN_WORLD_SEED"
echo "Region       : $VEILBORN_REGION"

# ─── Database migration ───────────────────────────────────────────────────────
if [[ -n "${VEILBORN_DATABASE_URL:-}" ]]; then
  echo ""
  echo "--- Running database migrations ---"
  python3 /app/migrations/run_migrations.py \
    --database-url "$VEILBORN_DATABASE_URL" \
    --migrations-dir /app/migrations/sql
  echo "Migrations complete."
fi

# ─── Pull chunks from S3 (seed the local cache) ──────────────────────────────
if [[ -n "${VEILBORN_S3_CHUNKS:-}" && -n "${VEILBORN_AWS_REGION:-}" ]]; then
  echo ""
  echo "--- Syncing chunks from S3 (this may take a moment) ---"
  aws s3 sync \
    "s3://${VEILBORN_S3_CHUNKS}/chunks/" \
    "${VEILBORN_DATA_DIR}/chunks/" \
    --region "${VEILBORN_AWS_REGION}" \
    --quiet \
    --no-progress \
    --exact-timestamps \
    || echo "WARN: S3 chunk sync failed (starting fresh)"
  
  CHUNK_COUNT=$(find "${VEILBORN_DATA_DIR}/chunks" -name "*.chunk" 2>/dev/null | wc -l)
  echo "Loaded $CHUNK_COUNT cached chunks from S3"
fi

# ─── Sync mods from S3 ───────────────────────────────────────────────────────
if [[ -n "${VEILBORN_S3_MODS:-}" && -n "${VEILBORN_AWS_REGION:-}" ]]; then
  echo ""
  echo "--- Syncing mods from S3 ---"
  aws s3 sync \
    "s3://${VEILBORN_S3_MODS}/mods/" \
    "${VEILBORN_DATA_DIR}/mods/" \
    --region "${VEILBORN_AWS_REGION}" \
    --quiet \
    --no-progress \
    || echo "WARN: Mod sync failed — no mods loaded"
  
  MOD_COUNT=$(find "${VEILBORN_DATA_DIR}/mods" -name "manifest.json" 2>/dev/null | wc -l)
  echo "Found $MOD_COUNT installed mods"
fi

# ─── Write runtime config for the Godot server ───────────────────────────────
cat > /tmp/server_runtime.json << EOF
{
  "port":             ${VEILBORN_PORT},
  "max_players":      ${VEILBORN_MAX_PLAYERS},
  "world_seed":       ${VEILBORN_WORLD_SEED},
  "region":           "${VEILBORN_REGION}",
  "environment":      "${VEILBORN_ENV}",
  "data_dir":         "${VEILBORN_DATA_DIR}",
  "log_dir":          "${VEILBORN_LOG_DIR}",
  "admin_port":       ${VEILBORN_ADMIN_PORT},
  "database_url":     "${VEILBORN_DATABASE_URL:-}",
  "redis_url":        "${VEILBORN_REDIS_URL:-}",
  "s3_chunks":        "${VEILBORN_S3_CHUNKS:-}",
  "aws_region":       "${VEILBORN_AWS_REGION:-}",
  "instance_id":      "${VEILBORN_INSTANCE_ID:-local}"
}
EOF

echo ""
echo "--- Starting Godot headless game server ---"
echo ""

# ─── Trap signals for graceful shutdown ──────────────────────────────────────
_shutdown() {
  echo ""
  echo "Shutdown signal received — flushing world state..."

  # Signal Godot server to drain
  kill -SIGTERM "$GODOT_PID" 2>/dev/null || true
  
  # Wait for it to exit gracefully (max 30s)
  WAIT=0
  while kill -0 "$GODOT_PID" 2>/dev/null && [[ $WAIT -lt 30 ]]; do
    sleep 1
    WAIT=$((WAIT + 1))
  done

  # Push final chunk sync
  if [[ -n "${VEILBORN_S3_CHUNKS:-}" && -n "${VEILBORN_AWS_REGION:-}" ]]; then
    echo "Final chunk sync to S3..."
    aws s3 sync \
      "${VEILBORN_DATA_DIR}/chunks/" \
      "s3://${VEILBORN_S3_CHUNKS}/chunks/" \
      --region "${VEILBORN_AWS_REGION}" \
      --quiet \
      --no-progress \
      || true
    echo "Final sync complete."
  fi

  echo "Shutdown complete."
  exit 0
}

trap '_shutdown' SIGTERM SIGINT SIGQUIT

# ─── Launch Godot headless server ────────────────────────────────────────────
/app/server/veilborn_server \
  --headless \
  --no-header \
  --config /tmp/server_runtime.json \
  >> "${VEILBORN_LOG_DIR}/server.log" 2>> "${VEILBORN_LOG_DIR}/error.log" &

GODOT_PID=$!
echo "Game server PID: $GODOT_PID"

# ─── Wait and restart if crash ────────────────────────────────────────────────
while true; do
  if ! wait "$GODOT_PID"; then
    EXIT_CODE=$?
    echo "Game server exited with code $EXIT_CODE at $(date)"

    # Don't restart on clean exit (code 0) or SIGTERM (143)
    if [[ $EXIT_CODE -eq 0 || $EXIT_CODE -eq 143 ]]; then
      echo "Clean exit — not restarting"
      break
    fi

    echo "Crash detected — restarting in 5s..."
    sleep 5

    /app/server/veilborn_server \
      --headless \
      --no-header \
      --config /tmp/server_runtime.json \
      >> "${VEILBORN_LOG_DIR}/server.log" 2>> "${VEILBORN_LOG_DIR}/error.log" &
    GODOT_PID=$!
    echo "Restarted with PID: $GODOT_PID"
  else
    break
  fi
done
