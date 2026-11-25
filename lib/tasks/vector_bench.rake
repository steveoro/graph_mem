# frozen_string_literal: true

# Step 1 of docs/plans/mariadb-vector-search-plan.md: bench vector search and write cost, by hand
# only, in a scratch database the task creates and drops (GraphMem::VectorBench::Sandbox). Prints
# Markdown for a PR body. Never scheduled or run in CI. See docs/development.md ("Vector bench").
namespace :graph_mem do
  desc "Bench vector search (exact vs index), recall and write cost with/without the VECTOR KEYs on synthetic rows " \
       "in a scratch DB (ROWS=10000 OBSERVATIONS=ROWS CLUSTERS=50 PROBES=20 WRITES=500 K=10 SEED=1 DB=<name>_vector_bench KEEP_DB=1)"
  task vector_bench: :environment do
    puts GraphMem::VectorBench::Runner.new(GraphMem::VectorBench::Runner::Options.from_env(ENV)).call
  rescue GraphMem::VectorBench::Sandbox::Refused, ArgumentError => e
    abort "graph_mem:vector_bench: #{e.message}"
  end
end
