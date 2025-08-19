#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench

# Run bench scheduler
exec bench schedule
