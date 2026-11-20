# frozen_string_literal: true

require "rails_helper"

# 1.92.0: the contradiction card marks the tokens that differ between its two sides.
RSpec.describe "Review contradiction highlight", type: :request do
  let!(:root) { fs_project!("Synth Project") }
  let!(:service_entity) { fs_member!(root, "SynthService", "Service") }

  before { sign_in_operator }

  def html = Nokogiri::HTML(response.body)

  def card_for(first_text, second_text)
    first = fs_observe!(service_entity, first_text)
    second = fs_observe!(service_entity, second_text)
    item = ContradictionDetector.review_item(ContradictionDetector::Result.new(observation_id_1: first.id, observation_id_2: second.id,
                                                                                distance: 0.05, confidence: 0.99))
    row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole
    get review_row_path(row.row_uuid)
    html.css("[data-testid='contradiction-sides']")
  end

  it "marks 3000 and 3001, and names the difference in a visually hidden line" do
    card = card_for("Port: 3000", "Port: 3001")

    expect(card.css("[data-testid='contradiction-text-1'] mark").map(&:text)).to eq([ "3000" ])
    expect(card.css("[data-testid='contradiction-text-2'] mark").map(&:text)).to eq([ "3001" ])
    expect(card.css("[data-testid='contradiction-text-1']").text).to eq("Port: 3000")
    expect(card.css(".review-sr-only").map(&:text)).to eq([ "Differs: 3000 → 3001", "Differs: 3001 → 3000" ])
  end

  it "marks an inserted word on the side that has it" do
    card = card_for("SynthService is supported", "SynthService is not supported")

    expect(card.css("mark").map(&:text)).to eq([ "not" ])
    expect(card.css(".review-sr-only").map(&:text)).to eq([ "Differs: — → not", "Differs: not → —" ])
  end

  it "marks nothing when more than three tokens differ on a side" do
    card = card_for("Runs alpha beta gamma delta", "Runs one two three four")

    expect(card.css("mark")).to be_empty
    expect(card.css(".review-sr-only")).to be_empty
    expect(card.text).to include("Runs alpha beta gamma delta", "Runs one two three four")
  end

  it "keeps HTML in the content escaped, inside and outside the marks" do
    card = card_for("Limit <b>bold</b> & <script>x</script>: 5", "Limit <b>bold</b> & <script>x</script>: 6")

    expect(card.css("b, script")).to be_empty
    expect(card.css("mark").map(&:text)).to eq(%w[5 6])
    expect(response.body).to include("Limit &lt;b&gt;bold&lt;/b&gt; &amp; &lt;script&gt;x&lt;/script&gt;: <mark>5</mark>")
  end

  it "doesn't mark a token past the 300-character cut" do
    long = "#{'word ' * 70}tail"
    card = card_for("#{long} 3000", "#{long} 3001")

    expect(card.css("mark")).to be_empty
    expect(card.css("[data-testid='contradiction-text-1']").text).to end_with("...")
  end
end
