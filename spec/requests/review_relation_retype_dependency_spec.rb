# frozen_string_literal: true

require "rails_helper"

# Dream State R1b: the Review card of a relation_retype `swap` or `add` row.
RSpec.describe "Review & Fix › relation_retype swap and add", type: :request do
  let!(:project) { fs_project!("SynthApp") }
  let!(:library) { fs_member!(project, "SynthLib", "Gem") }
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html" } }

  before do
    fs_member!(library, "SynthLib Notes", "Documentation")
    fs_member!(library, "SynthLib Config", "Configuration")
    sign_in_operator
  end

  def seed(item)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole
  end

  it "shows a swap's operation, endpoints, scope effect and evidence, and applies it" do
    fact = fs_observe!(project, "SynthApp uses SynthLib for parsing.")
    part_of = MemoryRelation.find_by!(from_entity_id: library.id, relation_type: "part_of")
    evidence = { entity_type: "Gem", facts: [ { observation_id: fact.id, entity_id: project.id, entity_name: "SynthApp", content: fact.content } ] }
    row = seed(CompactionReviewApplier::RelationRetypeDependency.swap_item(part_of, { library.id => "SynthLib", project.id => "SynthApp" },
                                                                          evidence: evidence))

    get review_row_path(row.row_uuid)

    expect(response).to have_http_status(:ok)
    card = Nokogiri::HTML5.fragment(response.body)
    expect(card.at_css("[data-testid='relation-retype-operation']").text.squish).to eq("Swap: part_of becomes the project's depends_on")
    expect(card.at_css("[data-testid='relation-retype-endpoints']").text)
      .to eq("'SynthLib' part_of 'SynthApp' becomes 'SynthApp' depends_on 'SynthLib': the project uses it rather than owns it.")
    expect(card.at_css("[data-testid='relation-retype-scope']").text).to eq("SynthLib and its 2 children leave SynthApp's scope (they become global)")
    evidence_items = card.css("[data-testid='relation-retype-evidence'] li").map { |li| li.text.squish }
    expect(evidence_items).to include(start_with("Type: Gem"), "##{fact.id} on SynthApp: SynthApp uses SynthLib for parsing.")
    expect(response.body).to include("swap: SynthApp depends_on SynthLib (was part_of)")

    post review_row_apply_path(row.row_uuid), headers: turbo

    expect(response).to have_http_status(:ok)
    expect(library.reload.project_id).to be_nil
    expect(MemoryRelation.exists?(from_entity_id: project.id, to_entity_id: library.id, relation_type: "depends_on")).to be(true)
  end

  it "shows an add's endpoints, its match and no scope change" do
    orphan = MemoryEntity.create!(name: "SynthTool", entity_type: "Tool")
    row = seed(CompactionReviewApplier::RelationRetypeDependency.add_item(project, orphan,
                                                                         evidence: { entity_type: "Tool", score: 10, matched_tokens: %w[synth] }))

    get review_row_path(row.row_uuid)

    card = Nokogiri::HTML5.fragment(response.body)
    expect(card.at_css("[data-testid='relation-retype-endpoints']").text)
      .to eq("'SynthTool' has no parent: 'SynthApp' depends_on 'SynthTool' is proposed instead of a part_of.")
    expect(card.at_css("[data-testid='relation-retype-scope']").text).to eq("No scope change: SynthTool keeps its scope.")
    expect(card.css("[data-testid='relation-retype-evidence'] li").map { |li| li.text.squish })
      .to include("Best project match: score 10 (tokens: synth)")
    expect(response.body).to include("Creates &#39;SynthApp&#39; depends_on &#39;SynthTool&#39;")
  end
end
