# frozen_string_literal: true

require "rails_helper"

# mcp plan PR-2 §2.20 item 7: allow_guest appends, and never mutates a parent class.
RSpec.describe RoleAuthorization do
  let(:parent) { Class.new { include RoleAuthorization } }

  it "keeps the actions from every allow_guest call" do
    parent.allow_guest :index
    parent.allow_guest :show, :index

    expect(parent._guest_allowed_actions).to eq(%w[index show])
  end

  it "lets a subclass add an action without changing its parent" do
    parent.allow_guest :index
    child = Class.new(parent) { allow_guest :results }

    expect(child._guest_allowed_actions).to eq(%w[index results])
    expect(parent._guest_allowed_actions).to eq(%w[index])
  end
end
