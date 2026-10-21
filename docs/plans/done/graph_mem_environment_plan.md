# GraphMem development environment plan

## Status

The repo-level Devin environment blueprint implements this plan. The commands
below were verified against Ruby 3.4.1 and the current locked bundle.

## Dependency maintenance

Use the official Ruby image and persist Bundler's install directory between
sessions:

```bash
mkdir -p "$HOME/.graph-mem-bundle-cache"
docker run --rm \
  -v "$PWD":/app \
  -v "$HOME/.graph-mem-bundle-cache":/bundle \
  -w /app \
  -e BUNDLE_PATH=/bundle \
  ruby:3.4.1 bundle install
```

Re-run this incremental command after `Gemfile` or `Gemfile.lock` changes.

## Local validation

Run static analysis through the same cached bundle:

```bash
docker run --rm \
  -v "$PWD":/app \
  -v "$HOME/.graph-mem-bundle-cache":/bundle \
  -w /app \
  -e BUNDLE_PATH=/bundle \
  ruby:3.4.1 bundle exec rubocop
```

```bash
docker run --rm \
  -v "$PWD":/app \
  -v "$HOME/.graph-mem-bundle-cache":/bundle \
  -w /app \
  -e BUNDLE_PATH=/bundle \
  ruby:3.4.1 bundle exec brakeman --no-pager
```

## Database-backed tests

Keep the authoritative RSpec run on CircleCI, which provides MariaDB 11.8.6
and its required native `VECTOR` support. GitHub Actions currently uses
MariaDB 10.11 and cannot load the repository's `VECTOR(768)` schema.
