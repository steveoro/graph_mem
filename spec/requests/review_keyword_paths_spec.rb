# frozen_string_literal: true

require "rails_helper"

# 1.78.0: contradiction and "Outdated by a fact" rows show each side's keyword path, the names both
# share in bold ("why these two").
RSpec.describe "Review keyword paths", type: :request do
  let!(:root) { fs_project!("Gadget Project") }
  let!(:grant) { fs_member!(root, "AdminGrant", "Model") }

  before do
    fs_member!(root, "User", "Model")
    sign_in_operator
  end

  def computed(observation) = observation.tap { FactKeywords.compute!([ observation.reload ]) }

  def html = Nokogiri::HTML(response.body)

  it "shows both paths of a contradiction, the shared name in bold" do
    first = computed(fs_observe!(grant, "It belongs to a User."))
    second = computed(fs_observe!(grant, "It does not belong to a User."))
    item = ContradictionDetector.review_item(ContradictionDetector::Result.new(observation_id_1: first.id, observation_id_2: second.id,
                                                                                distance: 0.1, confidence: 0.9))
    row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole

    get review_row_path(row.row_uuid)

    paths = html.css("[data-testid='keyword-path']")
    expect(paths.size).to eq(2)
    expect(paths.first.text.squish).to eq("Keywords: Gadget Project › AdminGrant › User")
    expect(paths.map { |path| path.css("strong").map(&:text) }).to all(eq([ "User" ]))
  end

  it "shows the source fact's and the observation's paths, and nothing for a pending one" do
    fact = computed(fs_fact!(grant, "AdminGrant now belongs to a User."))
    observation = fs_observe!(grant, "It belongs to a Team.")
    item = { "kind" => "fact_supersede", "fact_observation_id" => fact.id, "observation_id" => observation.id,
             "verdict" => FactSupersede::Judge::UNJUDGED, "confidence" => 0.5, "signals" => { "scoped" => true },
             "content" => observation.content, "fact_content" => fact.content, "entity_id" => grant.id, "entity_name" => grant.name }
    row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "fact_supersede", source_ref: "fact:#{fact.id}",
                                              items: [ item ]).sole

    get review_row_path(row.row_uuid)

    expect(html.css("[data-testid='keyword-path']").map { |path| path.text.squish }).to eq([ "Keywords: Gadget Project › AdminGrant › User" ])
  end

  it "shows the LLM words of two facts that name no entity, the shared ones in bold (1.83.0)" do
    first, second = [ [ "Validates presence of email.", %w[email presence] ], [ "Validates presence.", %w[presence] ] ].map do |content, words|
      computed(fs_observe!(grant, content)).tap { |fact| fact.update_columns(llm_keywords: words, llm_keywords_at: Time.current) }
    end
    item = ContradictionDetector.review_item(ContradictionDetector::Result.new(observation_id_1: first.id, observation_id_2: second.id,
                                                                                distance: 0.1, confidence: 0.9))
    row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole

    get review_row_path(row.row_uuid)

    words = html.css("[data-testid='llm-words']")
    expect(words.map { |node| node.text.squish }).to eq([ "LLM: email presence", "LLM: presence" ])
    expect(words.map { |node| node.css("strong").map(&:text) }).to all(eq([ "presence" ]))
  end
end
