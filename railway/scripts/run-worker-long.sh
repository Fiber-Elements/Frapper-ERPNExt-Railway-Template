#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench

# Run long queue worker (also handles default if desired)
exec bench worker --queue long,default,short
