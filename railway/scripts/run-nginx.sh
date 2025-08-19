#!/usr/bin/env bash
set -euo pipefail

# Frontend (nginx) entrypoint; relies on env BACKEND, SOCKETIO, and nginx-related vars
exec nginx-entrypoint.sh
