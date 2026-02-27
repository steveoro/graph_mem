# syntax=docker/dockerfile:1
# check=error=true

# Build and run:
#   docker compose up --build
# Or standalone:
#   docker build -t graph_mem .
#   docker run -d -p 3003:3003 -e RAILS_MASTER_KEY=<key> --name graph_mem graph_mem

ARG RUBY_VERSION=3.4.1
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Install base packages: MariaDB client libs (for mysql2 gem) + CLI (for db:dump/restore)
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libjemalloc2 libvips sqlite3 bzip2 \
      libmariadb3 mariadb-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

# Throw-away build stage to reduce size of final image
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libyaml-dev pkg-config \
      libmariadb-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY . .

RUN bundle exec bootsnap precompile app/ lib/

RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage for app image
FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3003
CMD ["./bin/rails", "server", "-b", "0.0.0.0", "-p", "3003"]
