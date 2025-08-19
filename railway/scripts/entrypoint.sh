#!/usr/bin/env bash
set -euo pipefail

# Runtime init: ensure mounted sites volume is owned by frappe and apps.txt exists
SITES_DIR=/home/frappe/frappe-bench/sites
APPS_DIR=/home/frappe/frappe-bench/apps

# Fix ownership (volume is mounted at runtime, so build-time chown won't persist)
if chown -R 1000:1000 "$SITES_DIR" 2>/dev/null; then
  echo "[INIT] Ownership of $SITES_DIR set to 1000:1000"
else
  echo "[WARN] Could not chown $SITES_DIR. Continuing; processes may fail if volume is not writeable by user 1000"
fi

# Generate apps.txt if missing
if [[ ! -f "$SITES_DIR/apps.txt" ]]; then
  if [[ -d "$APPS_DIR" ]]; then
    ls -1 "$APPS_DIR" > "$SITES_DIR/apps.txt" || true
    echo "[INIT] Generated $SITES_DIR/apps.txt"
  else
    echo "[WARN] $APPS_DIR not found; cannot generate apps.txt"
  fi
fi

# Show quick debug info
id || true
ls -l "$SITES_DIR" || true

# Start supervisord
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
