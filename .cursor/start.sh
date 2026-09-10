#!/usr/bin/env bash
#
# Cloud Agent start script for GraphMem.
#
# Runs on every boot. Processes do not survive between boots, so the MariaDB
# daemon (whose data directory is provisioned by install.sh and persisted in the
# snapshot) must be (re)started here. Must be idempotent and return once ready.
set -euo pipefail

if ! sudo mariadb -e "SELECT 1" >/dev/null 2>&1; then
  sudo install -d -o mysql -g mysql /run/mysqld 2>/dev/null || true
  sudo service mariadb start >/dev/null 2>&1 || true
  if ! sudo mariadb -e "SELECT 1" >/dev/null 2>&1; then
    sudo bash -c 'nohup mariadbd-safe --datadir=/var/lib/mysql >/var/log/mariadbd-safe.log 2>&1 &'
  fi
fi

for _ in $(seq 1 60); do
  if sudo mariadb -e "SELECT 1" >/dev/null 2>&1; then
    echo "MariaDB is ready"
    exit 0
  fi
  sleep 1
done

echo "MariaDB did not become ready in time" >&2
exit 1
