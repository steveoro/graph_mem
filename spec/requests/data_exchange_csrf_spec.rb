# frozen_string_literal: true

require "rails_helper"

# mcp plan PR-2 §2.20 item 8: the graph UI's JSON writes no longer skip CSRF.
# Test env disables forgery protection globally; it is turned on after sign-in.
# Both rows of a pair send the same valid params, so a 422 can only come from the CSRF check.
RSpec.describe "DataExchange CSRF protection", type: :request do
  let(:hex) { SecureRandom.hex(4) }
  let!(:project) { MemoryEntity.create!(name: "Alpha Service #{hex}", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget A #{hex}", entity_type: "Task") }
  let!(:other_widget) { MemoryEntity.create!(name: "SynthWidget B #{hex}", entity_type: "Task") }
  let!(:relation) { MemoryRelation.create!(from_entity: widget, to_entity: other_widget, relation_type: "relates_to") }

  writes = {
    export_async: [ :post, -> { { ids: [ project.id ] } } ],
    move_node: [ :post, -> { { node_id: widget.id, parent_id: project.id } } ],
    merge_node: [ :post, -> { { source_id: widget.id, target_id: other_widget.id } } ],
    delete_node: [ :delete, -> { { node_id: widget.id } } ],
    delete_duplicate_relations: [ :delete, -> { {} } ],
    create_relation: [ :post, -> { { from_id: other_widget.id, to_id: project.id, relation_type: "depends_on" } } ],
    update_relation: [ :patch, -> { { id: relation.id, relation_type: "depends_on" } } ],
    delete_relation: [ :delete, -> { { id: relation.id } } ]
  }

  before do
    sign_in_operator
    ActionController::Base.allow_forgery_protection = true # after sign-in: the login POST needs no token
  end

  after { ActionController::Base.allow_forgery_protection = false }

  def csrf_token
    get root_path
    response.body[/name="csrf-token" content="([^"]+)"/, 1].tap { |token| expect(token).to be_present }
  end

  writes.each do |action, (verb, params)|
    describe action.to_s do
      let(:path) { "/data_exchange/#{action}" }

      it "rejects a session write without a CSRF token with 422" do
        send(verb, path, params: instance_exec(&params), as: :json)

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "accepts a session write carrying the CSRF token" do
        send(verb, path, params: instance_exec(&params), as: :json, headers: { "X-CSRF-Token" => csrf_token })

        expect(response).to have_http_status(:success)
      end
    end
  end
end
