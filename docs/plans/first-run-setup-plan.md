# Plan: a fresh clone boots without a shared master key or a hand-made database.yml

> Status: **ready, priority.** Steve said go on 2026-11-27: this PR ships before the other open PRs,
> which are updated on top of it afterwards. Written against `main` at `e178003` (1.94.0 plus the #206
> docs commit), for issue #206. One PR, branch `claude/first-run-setup`. The version is whatever is
> next when it ships (see "Release"). The kickoff pulls `main` first and rechecks the line references
> against it.
>
> Motivation: #206. Following `docs/quick_setup.md` on a fresh clone, the `app` container restarts in
> a loop: `config/database.yml` is git-ignored, so the image has no `cable` database. The docs fix
> (copy `config/database.example.yml`) is already on `main` as `e178003` ("docs: create
> config/database.yml in setup steps (refs #206)"): quick_setup step 1 and the README Quick Start copy
> the example, `docs/development.md` names the right file, and quick_setup and
> `docs/troubleshooting.md` cover the cable error. This plan makes the container boot without that
> step and without a master key, and keeps every existing setup working unchanged.

## Goal

1. An image built from a fresh clone gets a working `config/database.yml` without a manual copy.
2. The container boots without `RAILS_MASTER_KEY` and without a credentials file: `secret_key_base`
   comes from `SECRET_KEY_BASE`, or from a key generated on first boot and kept in the `storage`
   volume.
3. A setup that already has `config/database.yml`, `config/master.key`, `config/credentials.yml.enc`
   and `RAILS_MASTER_KEY` in `.env` behaves exactly as today.
4. A configuration error that can't be fixed at boot prints one clear line and the fix, not a stack
   trace.
5. `config/credentials.yml.enc` stops being tracked (it is already in `.gitignore`).

Out of scope: new gems, MCP params or outputs, Kamal (`config/deploy.yml`), a committed ENV-only
`config/database.yml` (it would collide with the untracked local copy every existing checkout has).

## Current state (main at e178003)

- `.gitignore` lists `/config/database.yml`, `/config/master.key` and `config/credentials.yml.enc`,
  but `config/credentials.yml.enc` is tracked (since the first commit), so its ignore line does nothing.
- `.dockerignore` excludes `/config/master.key` but neither `config/database.yml` nor
  `config/credentials.yml.enc`: `COPY . .` bakes whatever the build context has into the image.
- `Dockerfile`: no step creates `config/database.yml`. Assets build with `SECRET_KEY_BASE_DUMMY=1`.
- `docker-compose.yml` (`app`): passes `RAILS_MASTER_KEY` and `DATABASE_URL`; there is no
  `env_file`, so a `SECRET_KEY_BASE` line in `.env` never reaches the container.
  `restart: unless-stopped`.
- `bin/docker-entrypoint`: `db:prepare`, then `db:support:initialize`, then the server. No preflight.
- What reads the credentials at boot (Rails 8.1.4.1):
  - `secret_key_base`: `ENV["SECRET_KEY_BASE"] || credentials.secret_key_base`; missing in
    production raises `ArgumentError: Missing secret_key_base` during boot.
  - The `active_record_encryption.configuration` initializer reads
    `credentials.dig(:active_record_encryption, ...)` at boot, so a credentials file with a **wrong**
    key raises `ActiveSupport::MessageEncryptor::InvalidMessage` even when `SECRET_KEY_BASE` is set.
    A missing key (no `RAILS_MASTER_KEY`, no `config/master.key`) is not an error:
    `require_master_key` is off, so the credentials read as empty.
  - The app itself reads only `operator.username` / `operator.password`, after
    `OPERATOR_USERNAME` / `OPERATOR_PASSWORD` (`ApplicationController`, `GraphMem::OperatorCredentials`).
    No model uses `encrypts`.

Checked locally on the 1.94.0 tree (85c0c4c; the docs commit changes no code) with `bin/rails runner` in production (no database needed):

| database.yml | credentials.yml.enc | RAILS_MASTER_KEY | SECRET_KEY_BASE | Result |
|---|---|---|---|---|
| missing | tracked file | empty | unset | `cable` database not configured (#206) |
| example | tracked file | empty | unset | Missing `secret_key_base` |
| example | tracked file | empty | set | boots |
| example | tracked file | wrong | set | `InvalidMessage` at boot |
| example | absent | wrong | set | boots |
| example | absent | empty | unset | Missing `secret_key_base` |

## Step 1: `config/database.yml` from the example when missing

`Dockerfile`, build stage, right after `COPY . .`:

```dockerfile
# A fresh clone has no config/database.yml (git-ignored): use the example (#206).
RUN [ -f config/database.yml ] || cp config/database.example.yml config/database.yml
```

The build stage keeps a local `config/database.yml` (in the build context) as it is. The example's
`production` section already reads `DATABASE_URL` for `primary` and puts cache, queue and cable in
SQLite under `storage/`.

`bin/setup`: replace the commented-out `database.yml.sample` block with the same copy from
`config/database.example.yml` (for native development).

## Step 2: `SECRET_KEY_BASE` without a master key

`docker-compose.yml`, `app.environment`: add `SECRET_KEY_BASE: ${SECRET_KEY_BASE:-}` next to
`RAILS_MASTER_KEY`.

`bin/docker-entrypoint`, before `db:prepare`, only for the server command:

- If `SECRET_KEY_BASE` is empty **and** `RAILS_MASTER_KEY` is empty **and**
  `config/master.key` is absent, use `storage/secret_key_base` (create it on first boot: 128 hex
  characters from `ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'`, written with `umask 077`),
  and export `SECRET_KEY_BASE` from it. Print one line: `secret_key_base: generated and kept in the
  storage volume (set SECRET_KEY_BASE in .env to choose your own)` on the first boot, nothing later.
- With a master key, change nothing: the credentials provide `secret_key_base`, as today.
- Never print the value.

`storage/` is the `graph_mem_storage` volume, so the key survives rebuilds and `docker compose down`.
Removing the volume (`down -v`) signs everyone out, nothing else: the app keeps no encrypted columns.

## Step 3: clear errors instead of stack traces

`bin/docker-entrypoint`, same preflight, before `db:prepare`:

- `config/credentials.yml.enc` present and `RAILS_MASTER_KEY` set: decrypt the file with a short
  `bundle exec ruby` check that doesn't boot the app (`ActiveSupport::EncryptedConfiguration` with
  `env_key: "RAILS_MASTER_KEY"`; booting would itself die on the same error) and, on
  `ActiveSupport::MessageEncryptor::InvalidMessage`, print
  `RAILS_MASTER_KEY doesn't match config/credentials.yml.enc: fix the key in .env, or remove the key
  and the file to boot without credentials (docs/quick_setup.md)` and `exit 1`.
- `config/database.yml` missing at runtime (an image built before step 1): print the `cp` fix and
  `exit 1`.

The container still restarts (`unless-stopped`), but every restart logs the one-line fix. Keep
`restart: unless-stopped`: it is what brings the stack back after a reboot.

## Step 4: stop tracking `config/credentials.yml.enc`

`git rm --cached config/credentials.yml.enc` (the `.gitignore` line is already there). Do it as the
last code commit, after steps 1-3 are green.

**In the checkout where the PR is built:** if it holds a real `config/credentials.yml.enc` or
`config/master.key`, copy both outside the repo before this commit and check they are still there
after every branch switch. Once the file is ignored on the branch, switching between `main` (tracked)
and the branch (removed) can rewrite or delete the working copy. Never regenerate, re-encrypt or
commit either file; a test that needs credentials uses its own throwaway key and file in a temp dir.

**For Steve, after the merge, before pulling `main` on each workstation** (the PR description
repeats this): a pull that removes a tracked file deletes the working copy too. On every checkout that uses the file:

```bash
mkdir -p ~/graph_mem-keys                                          # any folder outside the repo
cp config/credentials.yml.enc config/master.key ~/graph_mem-keys/
git pull                                                            # deletes config/credentials.yml.enc
cp ~/graph_mem-keys/credentials.yml.enc config/                     # back, now ignored
git status --short config/                                          # prints nothing
docker compose down && bin/up --build
```

If the pull stops with "Your local changes ... would be overwritten" (the file was regenerated
locally), move it aside first (`mv config/credentials.yml.enc ~/graph_mem-keys/`), then
`git checkout -- config/credentials.yml.enc`, pull, and copy it back. `config/master.key` is never
touched (untracked).

## Step 5: docs

Build on the docs from `e178003`; don't redo them.

- `docs/quick_setup.md`: step 1's `cp config/database.example.yml config/database.yml` becomes
  optional (the image falls back to the example); keep it for anyone who wants to edit the file.
  The cable-error troubleshooting row stays for images built before this PR. Step 2 ("Generate your
  own master key") goes. `.env` gets an optional
  `SECRET_KEY_BASE` (`openssl rand -hex 64`); without it graph_mem generates one. A short note keeps
  the master-key route for anyone who wants Rails credentials. Troubleshooting rows for the two new
  messages.
- `.env.example`: `SECRET_KEY_BASE=` with a comment; `RAILS_MASTER_KEY` marked optional.
- `README.md` Quick Start and the configuration table: same.
- `docs/troubleshooting.md`: keep the cable-error section from `e178003`, and note that images
  built after this PR no longer hit it.
- `docs/development.md` (its `database.example.yml` copy step is already fixed): native development needs no key (Rails generates `tmp/local_secret.txt`).
- CHANGELOG entry (see "Release").

## Release

No version is fixed here: the PR takes whatever version is next when it ships (Steve says which).
Bump the usual release files together and keep them in agreement (`lib/graph_mem/version.rb`, the
version line in `skills/graph-mem-mcp-toolset/SKILL.md`, the README version badge), and add a
`CHANGELOG.md` entry for that version with an **Upgrade** paragraph:

- Nothing to run for an existing setup: a local `config/database.yml`, `config/master.key` and
  `RAILS_MASTER_KEY` keep working as before.
- `config/credentials.yml.enc` is no longer tracked: back it up before pulling (the step 4 sequence).
- A new setup needs neither a master key nor a manual `config/database.yml`; `SECRET_KEY_BASE` in
  `.env` is optional.
- Fixed: a fresh clone's container no longer restarts in a loop on the missing `cable` database (#206).

## Checkpoints

Push-and-continue, no stop for review: push, get CI green, carry on.

1. After steps 1 and 2: open the PR as a draft.
2. After step 3.
3. After steps 4, 5 and the release files: mark the PR ready for review.

## Tests

- Entrypoint: a spec (or a `bin/` shell test like the existing `bin/up` ones, if any) that runs the
  preflight with a temporary `storage/` and checks: key generated once with mode 0600, reused on the
  second run, not generated when `RAILS_MASTER_KEY` or `SECRET_KEY_BASE` is set, value never printed.
- Wrong-key message: a fixture credentials file encrypted with a throwaway key, checked with another
  throwaway key.
- Docker, when available locally: build from a clean export (`git archive HEAD | docker build -`) with an empty `.env`
  except `DB_PASSWORD` and `OPERATOR_PASSWORD`, then `curl -s localhost:3030/up` returns 200. Report
  the result in the PR, or say it wasn't run; CI doesn't build the image.
- The existing suite stays green (CircleCI rspec, rubocop, brakeman; GitHub Actions).

## Acceptance

- #206's steps on a fresh clone, with no `config/database.yml`, no master key and no credentials file,
  boot the container and `/up` returns 200.
- A checkout with its own `config/database.yml`, `config/master.key`, `config/credentials.yml.enc`
  and `RAILS_MASTER_KEY` builds and boots with the same `secret_key_base` as before (existing
  sessions stay valid).
