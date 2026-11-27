# frozen_string_literal: true

require "rails_helper"

# 1.96.1 (review guidance, item 2): an "Outdated by a fact" card whose legacy guard fired says what
# that means, under the guard line and again in front of the judge's suggested replacement.
RSpec.describe "Review & Fix › Outdated by a fact › guard hint", type: :request do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let(:fact) { fs_fact!(gadget, "The MCP server uses the official mcp gem.") }

  before { sign_in_operator }

  def hint_tail(fact = "source fact")
    "this observation names a version or an environment that the #{fact} doesn't, or it is a work-log entry (true when written). " \
      "Old isn't wrong, so Dismiss unless the #{fact} really replaces it."
  end

  # A row as Proposals.item writes it, with the guard LegacyGuard really gives the observation.
  def row_for(content, verdict:, replacement: nil, perspective: nil, **extra)
    old = fs_observe!(widget, content, perspective: perspective)
    guard, guard_reason = FactSupersede::LegacyGuard.new(fact).check(old)
    item = { "kind" => "fact_supersede", "fact_observation_id" => fact.id, "observation_id" => old.id, "verdict" => verdict,
             "confidence" => 0.7, "replacement" => replacement, "guard" => guard, "guard_reason" => guard_reason,
             "signals" => { "scoped" => true }, "content" => old.content, "fact_content" => fact.content, "entity_id" => widget.id,
             "entity_name" => widget.name, "project_id" => gadget.id, "project_name" => gadget.name, **extra }
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole
  end

  def card(row)
    get review_row_path(row.row_uuid)
    Nokogiri::HTML5.fragment(response.body)
  end

  it "explains a context guard under it, in front of a judged replacement and above the confirm card's text" do
    row = row_for("The MCP server runs on fast-mcp 1.2 in staging.", verdict: "superseded", replacement: "The MCP server runs on the official mcp gem.")
    html = card(row)

    expect(html.at_css("[data-testid='fact-supersede-guard']").text).to start_with("Guard: context (names a version the fact doesn't")
    hint = "The guard disagrees with the judge: #{hint_tail}"
    expect(html.at_css("[data-testid='fact-supersede-guard-hint']").text).to eq(hint)
    replacement_hint = html.at_css("[data-testid='fact-supersede-replacement-hint']")
    expect(replacement_hint.text).to eq(hint)
    expect(replacement_hint.next_element["data-testid"]).to eq("fact-supersede-replacement")

    get review_row_preview_path(row.row_uuid, fact_action: "supersede")
    form = Nokogiri::HTML5.fragment(response.body).at_css("[data-testid='fact-supersede-apply-form']")
    expect(form.at_css("[data-testid='fact-supersede-apply-guard-hint']").text).to eq(hint)
    expect(form.at_css("textarea[name='replacement']").text.strip).to eq("The MCP server runs on the official mcp gem.")
    get review_row_preview_path(row.row_uuid, fact_action: "retire")
    expect(response.body).not_to include("fact-supersede-apply-guard-hint")
  end

  it "names the newer observation on a contradiction-fallback row" do
    row = row_for("The MCP server ran on fast-mcp 1.2.", verdict: "superseded", replacement: "The MCP server runs on the official mcp gem.",
                  "origin" => FactSupersede::ContradictionFallback::ORIGIN)

    expect(card(row).at_css("[data-testid='fact-supersede-guard-hint']").text)
      .to eq("The guard disagrees with the judge: #{hint_tail('newer observation')}")
  end

  it "says the guard disagrees with the proposal on an unjudged row, which has no replacement" do
    html = card(row_for("Moved the server off fast-mcp today.", verdict: FactSupersede::Judge::UNJUDGED, perspective: "experience"))

    expect(html.at_css("[data-testid='fact-supersede-guard-hint']").text).to eq("The guard disagrees with this proposal: #{hint_tail}")
    expect(html.at_css("[data-testid='fact-supersede-replacement-hint']")).to be_nil
  end

  it "shows no hint when no guard fired" do
    html = card(row_for("The MCP server runs on fast-mcp.", verdict: "superseded", replacement: "The MCP server runs on the official mcp gem."))

    expect(html.at_css("[data-testid='fact-supersede-guard']")).to be_nil
    expect(html.css("[data-testid='fact-supersede-guard-hint'], [data-testid='fact-supersede-replacement-hint']")).to be_empty
    expect(html.at_css("[data-testid='fact-supersede-replacement']").text).to eq("Suggested replacement: The MCP server runs on the official mcp gem.")
  end
end
