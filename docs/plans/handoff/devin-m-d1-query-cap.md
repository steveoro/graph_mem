# Devin Handoff: M-D1 — Search query cap

**Repo:** `steveoro/graph_mem`  
**Branch:** `devin/m-d1-query-cap` (off current `main`)  
**Depends on:** nothing — may merge before PR-2  
**PR-2 only checks:** M-D1 specs are present and green before it merges

---

## What to build

Enforce a 2,048-character cap on every free-text `query` argument across six MCP tool classes.  
Do it in **three layers**: a shared concern (schema + runtime guard), `:query` schema annotations, and `call` guards.

---

## Step-by-step

### Step 1 — New concern

Create **`app/tools/concerns/search_query_limits.rb`**:

```ruby
# frozen_string_literal: true

module SearchQueryLimits
  MAX_QUERY_LENGTH = 2_048

  def self.check!(query)
    return if query.nil?
    raise FastMcp::Tool::InvalidArgumentsError, "Query is too long (max 2048 characters)." \
      if query.to_s.length > MAX_QUERY_LENGTH
  end
end
```

### Step 2 — Add `max_size?:` to every `:query` declaration

Edit the `:query` argument declaration in each of the six tool files below.  
Keep every other field exactly as it is today; only add `max_size?: SearchQueryLimits::MAX_QUERY_LENGTH`:

| File | Current declaration (approximate) | Change |
|---|---|---|
| `app/tools/search_tool.rb:34` | `optional(:query).maybe(:string)` | `optional(:query).maybe(:string, max_size?: SearchQueryLimits::MAX_QUERY_LENGTH)` |
| `app/tools/search_entities_tool.rb:26` | `required(:query).filled(:string)` or similar | append `max_size?: SearchQueryLimits::MAX_QUERY_LENGTH` |
| `app/tools/search_subgraph_tool.rb:36` | `required(:query).filled(:string)` | append `max_size?: SearchQueryLimits::MAX_QUERY_LENGTH` |
| `app/tools/get_entities_tool.rb:31` | `optional(:query)…` or `required(:query)…` | append `max_size?: SearchQueryLimits::MAX_QUERY_LENGTH` |
| `app/tools/get_entity_tool.rb:32` | similar | append `max_size?: SearchQueryLimits::MAX_QUERY_LENGTH` |
| `app/tools/rank_observations_tool.rb:28` | `optional(:query).filled…` | append `max_size?: SearchQueryLimits::MAX_QUERY_LENGTH` |

> **If the declaration doesn't match exactly**, read the file first and adjust accordingly.  
> **Do not guess at arguments you can't see** — stop and report if anything looks different.

### Step 3 — Add `SearchQueryLimits.check!` in each tool's `call`

Add the guard call next to each tool's existing blank/nil check.  
For `search_tool.rb`, that is near line 72 today.  
For the other five tools, locate the place where `query` is validated or first used.

```ruby
include SearchQueryLimits   # at the top of each tool class (or just call SearchQueryLimits.check!(query))
# then in call:
SearchQueryLimits.check!(query)
```

> Do not change any other logic in `call`.

### Step 4 — Specs

**Add to `spec/tools/search_tool_spec.rb`** (find the existing `call` context and add alongside):

```ruby
it "rejects queries longer than 2048 characters" do
  expect { tool.call(query: "a" * 2049) }
    .to raise_error(FastMcp::Tool::InvalidArgumentsError, /too long/)
end

it "accepts exactly 2048 characters" do
  allow(tool).to receive(:search_logic) { [] }  # stub the actual search
  expect { tool.call(query: "a" * 2048) }.not_to raise_error
end

it "advertises maxLength 2048 in its input schema" do
  schema = SearchTool.input_schema_to_json
  expect(schema.dig("properties", "query", "maxLength")).to eq(2048)
end
```

> Adjust method/class names to match the existing spec if different.

**Create `spec/tools/query_length_limits_spec.rb`** (new file):

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Query length limits across MCP tools" do
  tools_with_query = [
    SearchTool,
    SearchEntitiesTool,
    SearchSubgraphTool,
    GetEntitiesTool,
    GetEntityTool,
    RankObservationsTool
  ]

  tools_with_query.each do |tool_class|
    describe tool_class do
      it "advertises maxLength 2048 on the :query argument" do
        schema = tool_class.input_schema_to_json
        expect(schema.dig("properties", "query", "maxLength")).to eq(2048)
      end
    end
  end
end
```

> If any tool class name is different, check `app/tools/concerns/` or `GraphMem::McpToolRegistry` for the canonical name and correct it.

### Step 5 — CHANGELOG

In **`CHANGELOG.md`**, under the existing `## [Unreleased]` section, add to the **Added** subsection (create it if absent):

```
- 2,048-char cap (maxLength in schema) on every free-text `query` argument (M-D1).
```

---

## Running the suite

```bash
source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem
RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 bundle exec rails db:truncate_all 2>/dev/null || true
RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 bundle exec rspec spec/tools/search_tool_spec.rb spec/tools/query_length_limits_spec.rb
RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 bundle exec rspec   # full suite
RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 bundle exec rails db:truncate_all 2>/dev/null || true
bundle exec rubocop
```

All must be green. Leave 0 rows in the test DB.

---

## Done criteria

- [ ] `SearchQueryLimits` concern exists and the constant is `2048`
- [ ] All six tool files use `max_size?: SearchQueryLimits::MAX_QUERY_LENGTH` on their `:query` argument
- [ ] All six tool files call `SearchQueryLimits.check!(query)` in their `call`
- [ ] `spec/tools/search_tool_spec.rb` has the three new examples and all pass
- [ ] `spec/tools/query_length_limits_spec.rb` exists and all six schema assertions pass
- [ ] Full rspec suite green; rubocop clean; 0 test-DB rows
- [ ] CHANGELOG `[Unreleased]` entry present

---

## Stop and ask rules

- If the existing blank/nil check in a tool looks different from the plan's description, **stop and ask** rather than guessing.
- If `input_schema_to_json` doesn't exist or returns a different structure, **stop and ask**.
- Do **not** shorten any descriptions, change any other logic, or add features beyond this list.
- Do **not** bump the version; do **not** rename `## [Unreleased]` to a version number.
- Do **not** merge, push tags, or run `rake release`.
