#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench/sites

# Ensure apps.txt exists (bench expects ./apps.txt when sites_path='.')
if [[ ! -f apps.txt ]]; then
  ls -1 ../apps > apps.txt || true
fi

# Run long queue worker (also handles default if desired)
exec bench worker --queue long,default,short
