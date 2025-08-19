#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench/sites

# Run bench scheduler
exec bench schedule
