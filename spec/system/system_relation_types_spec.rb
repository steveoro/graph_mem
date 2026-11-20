# frozen_string_literal: true

require "rails_helper"

# R1a in a browser: from the Relation types card to the unmapped types page, map a type, then the
# sweep's dry run and its confirmation. The queued job isn't performed here (the job spec covers it).
RSpec.describe "System › Background jobs: relation types", type: :system do
  before do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    RelationTypeMapping.reset_canonicalize_cache!
    sign_in_through_form
    expect(page).to have_current_path(root_path, wait: 5)
  end

  after { RelationTypeMapping.reset_canonicalize_cache! }

  it "maps an unmapped type, then queues the sweep after its dry run" do
    from = MemoryEntity.create!(name: "SynthService", entity_type: "Service")
    to = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
    relation = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "synth_placeholder")
    relation.update_column(:relation_type, "Synth Link Kind")

    visit system_jobs_path
    wait_for_stimulus
    within("[data-testid='relation-types-card']") { click_link "Unmapped relation types (1)" }

    expect(page).to have_css("h1", text: "Unmapped relation types")
    within("[data-type='synth_link_kind']") do
      expect(page).to have_text("SynthService —Synth Link Kind→ SynthWidget")
      select "depends_on", from: "Canonical type for synth_link_kind"
      click_button "Map"
    end

    expect(page).to have_text("synth_link_kind now maps to depends_on: the next sweep retypes its 1 relation.")
    expect(page).to have_css("[data-testid='unmapped-relation-types-empty']")
    find("[data-testid='toast-link']", text: "Canonicalize relation types").click

    expect(page).to have_css("[data-testid='dry-run-retyped'] .system-stat__value", text: "1")
    accept_confirm { find("[data-testid='btn-relation-types-confirm']").click }

    expect(page).to have_text("Relation type sweep queued.")
    expect(page).to have_current_path(system_jobs_path)
    expect(relation.reload.relation_type).to eq("Synth Link Kind")
  end
end
