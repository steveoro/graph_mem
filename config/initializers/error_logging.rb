# frozen_string_literal: true

# Handled Rails.error reports (MCP internal errors, a failing Home widget) are logged once, with
# no tool arguments or filtered parameters; see GraphMem::ErrorLogSubscriber.
require_relative "../../lib/graph_mem/error_log_subscriber"

Rails.error.subscribe(GraphMem::ErrorLogSubscriber.new)
