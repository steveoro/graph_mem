#!/bin/sh
# The lockdown gate's entry point: lockdown_test.sh --profile <name> [--models a,b] [--listen-ip <ip>]
exec python3 "$(dirname "$0")/lockdown.py" "$@"
