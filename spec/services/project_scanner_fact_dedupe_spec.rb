# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# 1.76.0: a scan skips a fact its entity already holds in other words (embedding distance within
# project_scan_fact_duplicate_max_distance), and counts it; without embeddings only an exact repeat is
# skipped, as before.
RSpec.describe ProjectScanner, "reworded facts", :with_test_embeddings do
  include LlmSpecHelpers

  let(:root) { Dir.mktmpdir("fact-dedupe-scan") }
  let(:facts) { [ "SynthWidget renders gadget frames." ] }
  # Cosine distance 0 to the stored facts' vector, about 0.10, and 1.
  let(:near_vector) { Array.new(768, 0.1) }
  let(:close_vector) { Array.new(620, 0.1) + Array.new(148, 0.0) }
  let(:far_vector) { [ 1.0 ] + Array.new(767, 0.0) }
  let(:vectors) { {} }
  let(:widget_relations) { [] }
  let(:extra_items) { [] }
  let(:embedding_service) { EmbeddingService.new(config: { url: "http://test", model: "test", provider: "ollama", dims: 768 }) }
  let(:provider) do
    FakeProvider.new do |*|
      { ok: true, done_reason: "stop", prompt_tokens: 10, error: nil, latency_ms: 1.0,
        text: { project: { name: "Gadget Project" },
                architecture: [ { entity: { name: "SynthWidget", type: "Class" }, observations: facts, relations: widget_relations },
                                *extra_items ] }.to_json }
    end
  end

  before do
    File.write(File.join(root, "README.md"), "# Gadget Project\n\nSynthWidget renders gadget frames.\n")
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(EmbeddingService).to receive(:instance).and_return(embedding_service)
    # Stored facts are embedded with near_vector; a scanned fact is compared by its own vector.
    allow(embedding_service).to receive(:embed).and_return(near_vector)
    allow(embedding_service).to receive(:embed!) { |text| vectors.fetch(text, near_vector) }
  end

  after { FileUtils.rm_rf(root) }

  def scan
    with_llm_provider(provider) { described_class.new(project_root: root, project_name: "Gadget Project").call }
  end

  def widget_facts = MemoryEntity.find_by!(name: "SynthWidget").memory_observations.active.pluck(:content)

  it "skips a rescan's reworded fact and counts it, in the result and the numbers-only line" do
    scan
    facts.replace([ "SynthWidget draws the gadget frames." ])
    lines = []
    allow(Rails.logger).to receive(:info).and_wrap_original do |original, *args, &block|
      lines << args.first if args.first.to_s.start_with?("[scan] ")
      original.call(*args, &block)
    end

    result = scan

    expect(widget_facts).to eq([ "SynthWidget renders gadget frames." ])
    expect(result.observations_deduped).to eq(1)
    expect(result.to_h[:observations_deduped]).to eq(1)
    line = lines.grep(/observations_deduped/).sole
    expect(line).to include('"observations_deduped":1')
    expect(line).not_to include("SynthWidget")
  end

  it "writes a close rewording that names an entity the stored fact doesn't (1.78.0)" do
    extra_items.replace([ { entity: { name: "FrameBuffer", type: "Class" }, observations: [ "FrameBuffer keeps the last frames." ],
                            relations: [] } ])
    scan
    facts.replace([ "SynthWidget renders gadget frames into a FrameBuffer." ])

    result = scan

    expect(result.observations_deduped).to eq(0)
    expect(widget_facts).to contain_exactly("SynthWidget renders gadget frames.", "SynthWidget renders gadget frames into a FrameBuffer.")
  end

  it "writes a close rewording with a different detail (1.82.0)" do
    facts.replace([ "SynthWidget is developed using Rails 8.0." ])
    scan
    facts.replace([ "SynthWidget is updated using Rails 8.1." ])

    expect(scan.observations_deduped).to eq(0)
    expect(widget_facts).to contain_exactly("SynthWidget is developed using Rails 8.0.", "SynthWidget is updated using Rails 8.1.")
  end

  it "still skips a close rewording with the same detail (1.82.0)" do
    facts.replace([ "SynthWidget is updated using Rails 8.1." ])
    scan
    facts.replace([ "SynthWidget is built with Rails 8.1." ])

    expect(scan.observations_deduped).to eq(1)
    expect(widget_facts).to eq([ "SynthWidget is updated using Rails 8.1." ])
  end

  it "adds a distinct fact" do
    scan
    facts.replace([ "SynthWidget keeps a FrameBuffer." ])
    vectors["SynthWidget keeps a FrameBuffer."] = far_vector

    result = scan

    expect(widget_facts).to contain_exactly("SynthWidget renders gadget frames.", "SynthWidget keeps a FrameBuffer.")
    expect(result.observations_deduped).to eq(0)
  end

  it "honours the distance setting" do
    scan
    facts.replace([ "SynthWidget draws the gadget frames." ])
    vectors["SynthWidget draws the gadget frames."] = close_vector

    AppSettings.project_scan_fact_duplicate_max_distance = 0.05
    scan
    expect(widget_facts.size).to eq(2)
  ensure
    AppSettings.where(var: "project_scan_fact_duplicate_max_distance").delete_all
  end

  it "skips a close fact at the default distance" do
    scan
    facts.replace([ "SynthWidget draws the gadget frames." ])
    vectors["SynthWidget draws the gadget frames."] = close_vector

    expect(scan.observations_deduped).to eq(1)
  end

  it "adds the reworded fact, without an error, when embeddings are off or down" do
    scan
    facts.replace([ "SynthWidget draws the gadget frames." ])
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)
    expect(scan).to have_attributes(errors: [], observations_deduped: 0)

    facts.replace([ "SynthWidget paints the gadget frames." ])
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(embedding_service).to receive(:embed!).and_raise(EmbeddingService::EmbeddingError, "connection refused")
    expect(scan).to have_attributes(errors: [], observations_deduped: 0)
    expect(widget_facts.size).to eq(3)
  end

  it "asks a down embedding service once per scan, not once per fact" do
    scan
    facts.replace([ "SynthWidget paints the gadget frames.", "SynthWidget draws the gadget frames." ])
    allow(embedding_service).to receive(:embed!).and_raise(EmbeddingService::EmbeddingError, "connection refused")

    expect(scan).to have_attributes(errors: [], observations_deduped: 0)
    expect(embedding_service).to have_received(:embed!).once
    expect(widget_facts.size).to eq(3)
  end

  context "when the stored fact names another entity, which validation would move" do
    # A first scan's fact on SynthWidget that names only FrameBuffer: on the rescan the validator would
    # move it to FrameBuffer. A rescan that restates it (reworded or word for word) keeps it where it is,
    # so SynthWidget never ends up with neither wording.
    let(:facts) { [ "It belongs to a FrameBuffer." ] }
    let(:widget_relations) { [ { to: "Gadget Project", type: "part_of" } ] }
    let(:extra_items) do
      [ { entity: { name: "FrameBuffer", type: "Class" }, observations: [ "FrameBuffer keeps the last frames." ],
          relations: [ { to: "Gadget Project", type: "part_of" } ] } ]
    end

    it "keeps the stored fact when the rescan rewords it" do
      scan
      facts.replace([ "SynthWidget belongs to a FrameBuffer." ])

      result = scan

      expect(result.observations_deduped).to eq(1)
      expect(widget_facts).to eq([ "It belongs to a FrameBuffer." ])
      expect(result.observations_moved).to eq(0)
    end

    it "keeps the stored fact when the rescan repeats it word for word" do
      scan

      result = scan

      expect(widget_facts).to eq([ "It belongs to a FrameBuffer." ])
      expect(result.observations_moved).to eq(0)
    end

    it "saves the restated facts with the reconciled extraction, for a resumed validation" do
      scan
      operation = OperationProgress.start!(operation_type: "project_scan", operation_id: SecureRandom.uuid, total_count: 6,
                                           message: "Synthetic scan")
      stored = MemoryObservation.active.where(content: [ "It belongs to a FrameBuffer.", "FrameBuffer keeps the last frames." ]).pluck(:id)

      with_llm_provider(provider) do
        described_class.new(project_root: root, project_name: "Gadget Project", operation_progress: operation).call
      end

      # Both items' facts were restated word for word.
      expect(operation.reload.details.dig("extraction", "restated_observation_ids")).to match_array(stored)
    end
  end
end
