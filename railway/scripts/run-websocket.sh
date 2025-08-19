#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench

# Socket.IO server
exec node /home/frappe/frappe-bench/apps/frappe/socketio.js
