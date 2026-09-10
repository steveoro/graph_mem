#!/usr/bin/env bash
#
# Cloud Agent install script for GraphMem.
#
# Idempotent, non-interactive dependency + database setup that runs after the
# repository is checked out. With environment builds this runs once to create the
# base snapshot; without builds it runs during agent setup. Per-boot service
# startup lives in start.sh, not here.
set -euo pipefail

RUBY_VERSION="3.4.1"
GEMSET="graph_mem"
BUNDLER_VERSION="2.6.2"
DB_PASSWORD="${DB_PASSWORD:-my_password}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "==> [1/6] System packages (MariaDB 11.8, build toolchain)"
if ! command -v mariadbd >/dev/null 2>&1 || ! dpkg -s libmariadb-dev >/dev/null 2>&1; then
  if [ ! -f /etc/apt/sources.list.d/mariadb.sources ]; then
    curl -sSfL https://r.mariadb.com/downloads/mariadb_repo_setup -o /tmp/mariadb_repo_setup
    sudo bash /tmp/mariadb_repo_setup --mariadb-server-version="mariadb-11.8"
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  # mariadb-client-compat provides the `mysql`/`mysqldump` command names, which
  # Rails shells out to when loading db/structure.sql (schema_format = :sql).
  # It is only a Recommends of mariadb-client, so it must be listed explicitly
  # alongside --no-install-recommends.
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    mariadb-server mariadb-client mariadb-client-compat libmariadb-dev \
    build-essential git curl ca-certificates \
    libssl-dev libyaml-dev libreadline-dev zlib1g-dev libffi-dev libgdbm-dev \
    libncurses-dev libvips bzip2 sqlite3 autoconf bison pkg-config
else
  echo "    system packages already present, skipping apt"
fi

echo "==> [2/6] RVM + Ruby ${RUBY_VERSION}@${GEMSET}"
if [ ! -s "$HOME/.rvm/scripts/rvm" ]; then
  gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys \
    409B6B1796C275462A1703113804BB82D39DC0E3 \
    7D2BAF1CF37B13E2069D6956105BD0E739499BDB || true
  curl -sSL https://get.rvm.io | bash -s stable
fi
# rvm is a shell function; sourcing it can trip `set -u`, so relax it here.
set +u
# shellcheck disable=SC1090
source "$HOME/.rvm/scripts/rvm"
if ! rvm list strings 2>/dev/null | grep -q "^ruby-${RUBY_VERSION}$"; then
  rvm install "ruby-${RUBY_VERSION}"
fi
rvm use "ruby-${RUBY_VERSION}@${GEMSET}" --create
set -u
if ! gem list -i bundler -v "${BUNDLER_VERSION}" >/dev/null 2>&1; then
  gem install bundler -v "${BUNDLER_VERSION}"
fi

echo "==> [3/6] bundle install"
bundle "_${BUNDLER_VERSION}_" install

echo "==> [4/6] config/database.yml"
if [ ! -f config/database.yml ]; then
  cp config/database.example.yml config/database.yml
  echo "    created config/database.yml from example"
else
  echo "    config/database.yml already present"
fi

echo "==> [5/6] MariaDB service + databases"
# Start MariaDB robustly: `service` works on normal agent VMs; fall back to
# starting the daemon directly for build/container contexts where init is
# unavailable. Idempotent — returns immediately if already up.
if ! sudo mariadb -e "SELECT 1" >/dev/null 2>&1; then
  sudo install -d -o mysql -g mysql /run/mysqld 2>/dev/null || true
  sudo service mariadb start >/dev/null 2>&1 || true
  if ! sudo mariadb -e "SELECT 1" >/dev/null 2>&1; then
    sudo bash -c 'nohup mariadbd-safe --datadir=/var/lib/mysql >/var/log/mariadbd-safe.log 2>&1 &'
  fi
fi
for _ in $(seq 1 60); do
  if sudo mariadb -e "SELECT 1" >/dev/null 2>&1; then break; fi
  sleep 1
done
# Allow root to authenticate BOTH via password (used by the app, running as the
# non-root VM user) AND via the unix socket (so this script's `sudo mariadb`
# keeps working on reruns). This makes the block idempotent.
sudo mariadb <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_PASSWORD}') OR unix_socket;
CREATE DATABASE IF NOT EXISTS graph_mem CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS graph_mem_test CHARACTER SET utf8mb4;
FLUSH PRIVILEGES;
SQL

echo "==> [6/6] Rails database prepare + seed"
RAILS_ENV=development bin/rails db:prepare
RAILS_ENV=development bin/rails db:seed
RAILS_ENV=test bin/rails db:prepare

echo "==> install.sh complete"
