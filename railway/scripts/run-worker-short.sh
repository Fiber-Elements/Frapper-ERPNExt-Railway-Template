#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench/sites

# Run short + default queue worker
exec bench worker --queue short,default
