#!/bin/bash
# Wrapper script to set the correct RVM environment and working directory

echo "[RunnerLog] Starting mcp_graph_mem_runner.sh" >&2

echo "[RunnerLog] Shell identified as: $(ps -p $$ -o comm=)" >&2
echo "[RunnerLog] PATH: $PATH" >&2
echo "[RunnerLog] RVM_PATH: $RVM_PATH" >&2

# Try to source RVM if it's not already sourced
echo "[RunnerLog] Checking if RVM needs sourcing..." >&2
if ! command -v rvm >/dev/null || ! declare -F rvm >/dev/null; then
  echo "[RunnerLog] RVM not found or not a function, attempting to source..." >&2
  if [ -s "$HOME/.rvm/scripts/rvm" ]; then
    echo "[RunnerLog] Sourcing $HOME/.rvm/scripts/rvm" >&2
    # shellcheck source=/dev/null
    . "$HOME/.rvm/scripts/rvm"
    RVM_SOURCED=$?
    echo "[RunnerLog] Sourced $HOME/.rvm/scripts/rvm (exit code: $RVM_SOURCED)" >&2
  elif [ -s "/usr/local/rvm/scripts/rvm" ]; then
    echo "[RunnerLog] Sourcing /usr/local/rvm/scripts/rvm" >&2
    # shellcheck source=/dev/null
    . "/usr/local/rvm/scripts/rvm"
    RVM_SOURCED=$?
    echo "[RunnerLog] Sourced /usr/local/rvm/scripts/rvm (exit code: $RVM_SOURCED)" >&2
  else
    echo "[RunnerLog] Error: RVM script not found. Cannot set Ruby environment." >&2
    exit 1
  fi
else
  echo "[RunnerLog] RVM already available as a command/function." >&2
fi

echo "[RunnerLog] RVM type after sourcing attempt: $(type rvm || echo 'rvm not found')" >&2

# Get the directory where the script itself is located
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd) # Assumes bin is one level below project root
echo "[RunnerLog] Project root identified as: $PROJECT_ROOT" >&2

# Change to the project root directory
echo "[RunnerLog] Changing directory to $PROJECT_ROOT" >&2
cd "$PROJECT_ROOT" || { echo "[RunnerLog] Error: Failed to cd to $PROJECT_ROOT" >&2; exit 1; }
echo "[RunnerLog] Current directory: $(pwd)" >&2

# Use the project's RVM settings (.ruby-version, .ruby-gemset)
EXPECTED_RUBY_VERSION="ruby-3.4.1"
EXPECTED_GEMSET="graph_mem"
echo "[RunnerLog] Attempting to use RVM: ${EXPECTED_RUBY_VERSION}@${EXPECTED_GEMSET}" >&2

rvm use "${EXPECTED_RUBY_VERSION}@${EXPECTED_GEMSET}" --create
RVM_USE_EXIT_CODE=$?
echo "[RunnerLog] 'rvm use' exit code: ${RVM_USE_EXIT_CODE}" >&2

if [ ${RVM_USE_EXIT_CODE} -ne 0 ]; then
  echo "[RunnerLog] Error: RVM failed to use ${EXPECTED_RUBY_VERSION}@${EXPECTED_GEMSET}. Current RVM environment:" >&2
  rvm current >&2
  echo "[RunnerLog] Ruby version: $(ruby --version || echo 'ruby not found')" >&2
  echo "[RunnerLog] Gem env: $(gem env || echo 'gem not found')" >&2
  exit 1
fi

echo "[RunnerLog] Successfully set RVM environment: $(rvm current)" >&2
echo "[RunnerLog] Ruby version: $(ruby --version)" >&2
echo "[RunnerLog] Gem path: $(gem env path)" >&2
echo "[RunnerLog] Bundle path: $(bundle path)" >&2
echo "[RunnerLog] Which ruby: $(which ruby)" >&2
echo "[RunnerLog] Which bundle: $(which bundle)" >&2

# Execute the stdio runner script with Bundler
echo "[RunnerLog] Executing: bundle exec ruby ${SCRIPT_DIR}/mcp_stdio_runner.rb (STDERR redirected to ${PROJECT_ROOT}/log/graph_mem_ruby_stderr.log)" >&2
echo "" > "${PROJECT_ROOT}/log/graph_mem_ruby_stderr.log"
exec bundle exec ruby "${SCRIPT_DIR}/mcp_stdio_runner.rb" 2> "${PROJECT_ROOT}/log/graph_mem_ruby_stderr.log"
