#!/bin/bash
set -euo pipefail
python3 /opt/echo_server.py &
exec "$@"
