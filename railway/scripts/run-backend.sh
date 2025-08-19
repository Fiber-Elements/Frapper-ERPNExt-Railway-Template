#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench

# Start Gunicorn backend
if [[ -f config/gunicorn.conf.py ]]; then
  # Use provided config if available
  exec gunicorn -c /home/frappe/frappe-bench/config/gunicorn.conf.py frappe.app:application --preload
else
  echo "[WARN] gunicorn.conf.py not found at /home/frappe/frappe-bench/config/gunicorn.conf.py; starting with defaults"
  exec gunicorn --bind 0.0.0.0:8000 --workers 2 --timeout 120 frappe.app:application --preload
fi
