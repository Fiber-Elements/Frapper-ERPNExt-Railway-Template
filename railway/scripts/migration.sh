#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench

# Put all sites into maintenance and pause scheduler, run migrate, then revert
bench --site all set-config -p maintenance_mode 1
bench --site all set-config -p pause_scheduler 1

bench --site all migrate

bench --site all set-config -p maintenance_mode 0
bench --site all set-config -p pause_scheduler 0

echo "[OK] Migration completed for all sites"
