#!/bin/bash
# Wrapper script to run mikrotik_tui via mix run (avoids escript inet issues)
cd "$(dirname "$0")"
exec mix run --no-halt -- "$@"
