# Devin Handoff: M-D2 — Tool description length spec

**Repo:** `steveoro/graph_mem`  
**Branch:** `devin/m-d2-description-length` (off current `main`)  
**Depends on:** nothing — may merge before PR-2  
**PR-2 only checks:** M-D2 specs are present and green before it merges

---

## What to build

A new spec that asserts every MCP tool description (and the server instructions string) stays at or below **2,048 characters**.  
This is a guard, not a fix: if a description is already within 2,048 chars it just passes. If one is over the limit, mark it `pending` and report it in the PR.

---

## Step-by-step

### Step 1 — Find the tool registry

Open `lib/graph_mem/mcp_tool_registry.rb` and find how `McpToolRegistry.register_with!(server)` is called.  
The canonical list of tool classes is built there (both "visible" canonical tools and "hidden" alias tools).

You need to iterate **all** registered classes (canonical + aliases combined), since clients may call aliases and they all have descriptions.

### Step 2 — Find the server instructions string

Open `config/initializers/fast_mcp.rb`. The `FastMcp::Server.new(...)` call does **not** currently pass an `instructions:` keyword, so the server instructions string is `nil` / empty today. The spec should assert `<= 2048` on whatever that string is (blank passes trivially; this assertion will catch it if instructions are added later).

If `instructions:` is not a supported `FastMcp::Server` option in 1.7.x, skip the instructions assertion and add a comment: `# FastMcp::Server.new does not accept instructions: yet; assertion is a no-op placeholder`.

### Step 3 — Create the spec

Create **`spec/tools/tool_description_length_spec.rb`**:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MCP tool and server description lengths (M-D2)" do
  let(:all_tool_classes) do
    # Include both visible and hidden/alias tools.
    server = FastMcp::Server.new(name: "test", version: "0")
    GraphMem::McpToolRegistry.register_with!(server)
    server.tools   # returns the registered tool classes
  end

  describe "tool descriptions" do
    it "are all ≤ 2,048 characters" do
      long_tools = all_tool_classes.select do |klass|
        klass.description.to_s.length > 2048
      end

      if long_tools.any?
        names = long_tools.map { |k| "#{k.name} (#{k.description.to_s.length} chars)" }.join(", ")
        pending "The following tools exceed 2048 chars — wording is a design decision: #{names}"
      end

      expect(long_tools).to be_empty
    end
  end

  describe "server instructions" do
    let(:instructions) do
      # Read the instructions string from the initializer, if any.
      # FastMcp::Server exposes it as `server.instructions` or similar; adjust if needed.
      server = FastMcp::Server.new(name: "test", version: "0")
      server.respond_to?(:instructions) ? server.instructions.to_s : ""
    end

    it "is ≤ 2,048 characters" do
      expect(instructions.length).to be <= 2048
    end
  end
end
```

> **Adjust** the accessor name for the tool list (`server.tools`) or the instructions (`server.instructions`) to match the actual fast-mcp 1.7.x API.  
> If `register_with!` needs special arguments (e.g. a `profile:`) to return all tools, check `spec/integration/fast_mcp_registration_spec.rb` for the canonical call pattern.

### Step 4 — Run the spec

```bash
source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem
RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 bundle exec rspec spec/tools/tool_description_length_spec.rb --format documentation
```

If any examples are `pending`, list the tool names and their character counts in the PR description. **Do not shorten the descriptions yourself.**

### Step 5 — Full suite and rubocop

```bash
RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 bundle exec rails db:truncate_all 2>/dev/null || true
RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 bundle exec rspec
RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 bundle exec rails db:truncate_all 2>/dev/null || true
bundle exec rubocop
```

### Step 6 — CHANGELOG

In **`CHANGELOG.md`**, under the existing `## [Unreleased]` section, add to the **Added** subsection (create it if absent):

```
- Spec: tool descriptions and server instructions stay ≤ 2,048 chars (M-D2).
```

---

## Done criteria

- [ ] `spec/tools/tool_description_length_spec.rb` exists
- [ ] It iterates all tool classes (visible + aliases) registered by `McpToolRegistry`
- [ ] It asserts `description.to_s.length <= 2048` for each
- [ ] It asserts `server.instructions.to_s.length <= 2048` (or has a comment if instructions: is unsupported)
- [ ] Any over-limit tools are marked `pending` with their name + length (not silently deleted or shortened)
- [ ] Full rspec suite green (pending examples do not count as failures); rubocop clean; 0 test-DB rows
- [ ] CHANGELOG `[Unreleased]` entry present

---

## Stop and ask rules

- If `FastMcp::Server` has no `tools` or `instructions` accessor, **stop and ask** for the correct API name.
- If `McpToolRegistry.register_with!` signature has changed, **stop and ask**.
- Do **not** shorten any descriptions, change any other logic, or add features beyond this list.
- Do **not** bump the version; do **not** rename `## [Unreleased]` to a version number.
- Do **not** merge, push tags, or run `rake release`.
