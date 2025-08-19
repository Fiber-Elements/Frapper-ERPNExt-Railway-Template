#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench/sites

# Ensure apps.txt exists (bench expects ./apps.txt when sites_path='.')
if [[ ! -f apps.txt ]]; then
  if [[ -d ../apps ]]; then
    ls -1 ../apps > apps.txt
  else
    echo "[ERROR] ../apps directory not found from $(pwd); cannot generate apps.txt" >&2
    exit 1
  fi
  if [[ ! -s apps.txt ]]; then
    echo "[ERROR] apps.txt is missing or empty after generation; check volume permissions and /home/frappe/frappe-bench/apps" >&2
    exit 1
  fi
fi

# Run long queue worker (also handles default if desired)
exec bench worker --queue long,default,short
