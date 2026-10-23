# Project scans in a container

graph_mem's project scans read source files from disk. In Docker the container can only see
folders that are mounted into it, so `docker-compose.yml` mounts the host user's **home folder,
read-only, at the same path** inside the container. A host path such as
`/home/steve/Projects/foo` then works as typed, in the dashboard, `POST /api/v1/scan` and MCP
`scan_project`.

Three layers decide what can actually be scanned, all enforced by `ScanRootPolicy`:

1. **The scan root:** `GRAPH_MEM_SCAN_ROOTS` (the mounted home). Nothing outside it is visible.
2. **The subfolder filter:** Settings › Project scans, default `Projects`. Only these folders under
   the root are scannable. It is read on every scan request and at job start, so a change takes
   effect immediately, in every process, with no restart.
3. **The hard denylist** (never configurable):
   - **scan roots and project folders** can't be, or be inside, a hidden folder (`.ssh`, `.gnupg`,
     `.aws`, `.config`, …, anything starting with `.`, at any depth), and can't sit in `snap`,
     `Library`, `AppData`, `Maildir` or `Mail` directly under the scan root (a project called
     `library` deeper down is fine). A **home folder** (yours, `/root`, or any folder directly under
     `/home` or `/Users`) can't be scanned as one project: pick a folder inside it. `/home` and
     `/Users` themselves can't be scan roots;
   - **inside a project**, `.git`, `.ssh`, `.gnupg`, `.aws`, `.kube`, `.docker`, `.password-store`,
     `.env*`, key and certificate files, `credentials*`, `master.key`, `*.tfstate`, shell history and
     a few other secret files are never read, even when a `file_globs` entry names them (matching
     ignores case). Other project dot-folders such as `.github` stay readable through explicit
     globs; the default `**/*` scan skips every dot-file.

Settings › Project scans shows the mounted folders (read-only or read-write), the filter with the
status of each entry, the always-blocked list and a "check a path" box.

## Linux Docker (tested)

`docker-compose.yml`, `app` service:

```yaml
    environment:
      GRAPH_MEM_SCAN_ROOTS: ${GRAPH_MEM_SCAN_HOME:-${HOME}}
      GRAPH_MEM_SCANS: ${GRAPH_MEM_SCANS:-on}   # "off" disables scans without touching the mount
    volumes:
      - ${GRAPH_MEM_SCAN_HOME:-${HOME}}:${GRAPH_MEM_SCAN_HOME:-${HOME}}:ro
```

- `GRAPH_MEM_SCAN_HOME` (in `.env`) overrides the folder. Leave it empty to use the `HOME` of the
  user running compose; set it explicitly for systemd or cron, where `HOME` may be unset.
- Check the result with `docker compose config`: the volume must end in `:ro`.
- `docker run` equivalent: `-v "$HOME:$HOME:ro" -e GRAPH_MEM_SCAN_ROOTS="$HOME"`.
- Kamal (untested): `volumes: ["/home/deploy:/home/deploy:ro"]` plus `GRAPH_MEM_SCAN_ROOTS`.

**Always mount `:ro`.** The scanner never writes, and read-only keeps anything in the container
from touching your home. A read-write mount still works, but Settings and every scan result show
an amber "mounted read-write" warning.

If nothing is mounted at the scan root, scans are disabled and say so ("nothing is mounted").
A scan root can't be `/`, a system folder (`/usr`, `/etc`, `/var`, …), the app (`/rails`) or the
container user's own home (`/home/rails`).

## Narrowing the mount (recommended)

The default mounts your whole home, so the policy above is the only thing between the container
and `~/.ssh` or `~/.config`. If your projects all live in one folder, mount just that:

```bash
# .env
GRAPH_MEM_SCAN_HOME=/home/you/Projects
```

and set the subfolder filter in Settings › Project scans to **blank** (the default `Projects` would
look for `~/Projects/Projects`). Every project folder inside the mount is then scannable, and
nothing else of your home is visible to the container at all.

If `HOME` is unset (systemd, cron) and `GRAPH_MEM_SCAN_HOME` is empty, `docker compose` stops with
"set GRAPH_MEM_SCAN_HOME (HOME is unset)" instead of starting with a broken mount.

## UID and permissions

The app runs as uid/gid 1000. If your host uid is 1000 (the usual first user), it reads your files
as you. Otherwise grant read access to the scanned subfolders only:

```bash
setfacl -m u:1000:x "$HOME"                                  # traverse only
setfacl -R -m u:1000:rX -m d:u:1000:rX "$HOME/Projects"      # read the scanned folders
```

or use a shared group via `group_add`. **Never** `chmod -R o+r $HOME`. Don't change the container
`user:` either: `storage/`, `log/` and `tmp/` are owned by uid 1000.

## Rootless Podman (best-effort, not CI-tested)

`podman compose` works with the same file plus an override:

```yaml
services:
  app:
    userns_mode: "keep-id:uid=1000,gid=1000"   # your host uid ↔ container uid 1000 (Podman ≥ 4.3)
    security_opt: ["label=disable"]           # SELinux hosts: see below
```

Quadlet (`~/.config/containers/systemd/graph_mem.container`, after building or pulling the image):

```ini
[Container]
Image=localhost/graph_mem:latest
Network=host
UserNS=keep-id:uid=1000,gid=1000
SecurityLabelDisable=true
Volume=%h:%h:ro
Environment=GRAPH_MEM_SCAN_ROOTS=%h
EnvironmentFile=%h/.config/graph_mem/env
```

## SELinux (Fedora/RHEL, Podman or Docker)

An unlabelled bind mount reads as "permission denied".

**Never use `:z` or `:Z` on your home directory.** They relabel every file under it recursively,
which breaks other confined programs, and `:Z` makes the files private to this one container.
Instead:

- use `:ro` plus `label=disable` (as above; weaker isolation, for this container only), or
- mount one folder dedicated to graph_mem with `:ro,z` **only** (never your home), set
  `GRAPH_MEM_SCAN_HOME` to it and blank the subfolder filter: that folder and every project in it is scannable.

## Docker Desktop (macOS/Windows)

Untested. Identity mapping should work on macOS (`/Users/you`) once the folder is shared in Docker
Desktop. Windows paths need a path map, which graph_mem doesn't have yet.

## Changing what's scannable

- The **subfolder filter** is runtime: edit it in Settings › Project scans.
- The **mount** (`GRAPH_MEM_SCAN_HOME`) needs `docker compose up -d`, which recreates `app`.

## Symlinks

A project folder whose realpath leaves the scan root, or lands in a hidden or protected folder, is
refused. Inside a project, a file whose realpath leaves the project, or matches the in-project
denylist above, is never read; scanners read the realpath they checked, not the link.

## Native installs (`bin/dev`)

Without the container, the scan root is `GRAPH_MEM_SCAN_ROOTS` or, by default, your home folder,
with the same `Projects` filter. To scan somewhere else (for example `/tmp/foo`), set
`GRAPH_MEM_SCAN_ROOTS` or widen the filter. `PROJECT_SCAN_ROOTS` and the old "allowed project scan
roots" setting are no longer used.
