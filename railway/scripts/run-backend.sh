#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench

# Ensure bench path and config exist
if [[ ! -f config/gunicorn.conf.py ]]; then
  echo "[WARN] gunicorn.conf.py not found at /home/frappe/frappe-bench/config/gunicorn.conf.py"
fi

# Start Gunicorn backend (same as backend service in pwd.yml image default)
exec gunicorn -c /home/frappe/frappe-bench/config/gunicorn.conf.py frappe.app:application --preload
