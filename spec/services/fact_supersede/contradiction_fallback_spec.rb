# frozen_string_literal: true

require "rails_helper"

# 1.85.0 (Steve, decision 2): the contradiction detector's `:unknown` fallback pairs go through
# FactSupersede's filters instead of becoming contradiction rows: LegacyGuard, then the judge with
# the newer observation as the fact. Only a `superseded` verdict makes a fact_supersede item. HTTP
# is stubbed at Net::HTTP; no model service is reached.
RSpec.describe FactSupersede::ContradictionFallback do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:deployer) { fs_member!(gadget, "Deployer") }
  let!(:older) { fs_observe!(deployer, "Deploy by running the rake task by hand.", created_at: 3.days.ago) }
  let!(:newer) { fs_observe!(deployer, "Do not deploy by hand: run bin/deploy.") }
  let(:bodies) { [] }
  let(:answers) { [] }

  before do
    AppSettings.enable_llm_summarization = true
    AppSettings.summary_url = "http://summary.test:11434"
    AppSettings.summary_model = "synth-judge"
    AppSettings.summary_provider = "ollama"
    AppSettings.llm_keywords_enabled = false
    SummaryGenerationClient.reset_instance!
    http = instance_double(Net::HTTP, "use_ssl=": nil, "open_timeout=": nil, "read_timeout=": nil)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:request) do |request|
      bodies << JSON.parse(request.body)
      response = instance_double(Net::HTTPSuccess, body: { response: answers.shift.to_json }.to_json)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      response
    end
  end

  after do
    %w[enable_llm_summarization summary_url summary_model summary_provider llm_keywords_enabled].each { |var| AppSettings.where(var: var).delete_all }
    AppSettings.clear_cache
    SummaryGenerationClient.reset_instance!
  end

  def pair(first = older, second = newer, distance: 0.08)
    ContradictionDetector::Result.new(observation_id_1: first.id, observation_id_2: second.id, distance: distance, confidence: 0.95)
  end

  def verdict(observation, verdict, confidence: 0.9)
    { id: observation.id, verdict: verdict, confidence: confidence, reason: "The newer procedure replaces it." }
  end

  it "judges the older observation against the newer one and keeps a superseded verdict, in Find & supersede's shape" do
    answers << [ verdict(older, "superseded") ]

    result = described_class.call([ pair(newer, older) ])

    item = result.items.sole
    expect(item).to include("kind" => "fact_supersede", "fact_observation_id" => newer.id, "observation_id" => older.id,
                            "verdict" => "superseded", "confidence" => 0.9, "entity_id" => deployer.id, "project_id" => gadget.id,
                            "origin" => described_class::ORIGIN, "signals" => include("distance" => 0.08, "polarity_flip" => true))
    expect(item.keys).to include(*%w[fact_content fact_entity_name content entity_name project_name reason replacement guard
                                     guard_reason detected_at])
    expect(result).to have_attributes(judge_calls: 1, deferred: 0)
    prompt = bodies.sole["prompt"]
    expect(prompt.index(newer.content)).to be < prompt.index(older.content)
  end

  it "drops a still_valid verdict" do
    answers << [ verdict(older, "still_valid") ]

    expect(described_class.call([ pair ]).items).to be_empty
    expect(bodies.size).to eq(1)
  end

  it "skips a pair while either side's LLM words are pending, without calling the LLM" do
    AppSettings.llm_keywords_enabled = true
    older.update_columns(llm_keywords: %w[deploy], llm_keywords_at: Time.current)

    result = described_class.call([ pair ])

    expect(result).to have_attributes(items: [], deferred: 1, judge_calls: 0)
    expect(bodies).to be_empty
  end

  it "keeps what LegacyGuard keeps (another project) and pairs across projects, without calling the LLM" do
    legacy = fs_project!("Legacy Gadget")
    named = fs_observe!(deployer, "Legacy Gadget is deployed by hand.", created_at: 2.days.ago)
    elsewhere = fs_observe!(fs_member!(legacy, "LegacyDeployer"), "Deploy by hand with Capistrano.", created_at: 2.days.ago)

    result = described_class.call([ pair(named, newer), pair(elsewhere, newer) ])

    expect(result).to have_attributes(items: [], kept: 2, judge_calls: 0)
    expect(bodies).to be_empty
  end

  it "judges one owner's facts about another project's thing, guarded as context instead of kept (Graphy, #172)" do
    fs_project!("Ledger Service")
    was = fs_observe!(deployer, "It reads the invoices from Ledger Service.", created_at: 3.days.ago)
    now = fs_observe!(deployer, "It no longer reads the invoices from Ledger Service.")
    # Paths set by hand: both mention the other root (as a part_of edge between two roots once made it).
    [ was, now ].each { |fact| fact.update_columns(keywords: [ "Gadget Project", "Deployer", "Ledger Service" ], keywords_at: Time.current) }
    expect(ContradictionDetector.foreign_only?(was.reload, now.reload)).to be(true)
    answers << [ verdict(was, "superseded") ]

    item = described_class.call([ pair(was, now) ]).items.sole

    expect(item).to include("fact_observation_id" => now.id, "observation_id" => was.id, "guard" => FactSupersede::LegacyGuard::CONTEXT)
    expect(item["guard_reason"]).to include("names another project (Ledger Service)", "the judge decides")
  end

  it "skips quietly when the judge LLM isn't usable" do
    AppSettings.enable_llm_summarization = false

    expect(described_class.call([ pair ])).to have_attributes(items: [], judge_calls: 0)
    expect(bodies).to be_empty
  end

  it "skips a pair that already has a pending row or a dismissal" do
    answers << [ verdict(older, "superseded") ]
    row = CompactionReviewService.seed_report(report_type: "compaction_review", source: described_class::ORIGIN,
                                              items: described_class.call([ pair ]).items).sole
    CompactionReviewService.dismiss(row.row_uuid, reason: "both are right")

    expect(described_class.call([ pair ])).to have_attributes(items: [], known: 1, judge_calls: 0)
    expect(bodies.size).to eq(1)
  end

  it "bounds the judge calls per scan, closest pairs first" do
    stub_const("#{described_class}::MAX_JUDGE_CALLS", 1)
    other_newer = fs_observe!(deployer, "Never deploy on Fridays.")
    other_older = fs_observe!(deployer, "Deploy any day.", created_at: 3.days.ago)
    answers << [ verdict(older, "superseded") ]

    result = described_class.call([ pair(other_older, other_newer, distance: 0.12), pair(older, newer, distance: 0.05) ])

    expect(result.items.map { |item| item["observation_id"] }).to eq([ older.id ])
    expect(result).to have_attributes(judge_calls: 1, over_cap: 1)
    expect(result.leftovers.map(&:observation_id_1)).to eq([ other_older.id ])
  end

  # Review fix: the per-fact batch cut is counted, and every unjudged pair is a leftover to retry.
  it "counts the candidates one fact's batch cut leaves unjudged, and hands them back as leftovers" do
    stub_const("FactSupersede::Judge::BATCH_SIZE", 1)
    second_older = fs_observe!(deployer, "Deploy from a laptop.", created_at: 2.days.ago)
    answers << [ verdict(older, "still_valid") ]

    result = described_class.call([ pair(older, newer, distance: 0.05), pair(second_older, newer, distance: 0.1) ])

    expect(result).to have_attributes(judge_calls: 1, over_cap: 1)
    expect(result.leftovers.map(&:observation_id_1)).to eq([ second_older.id ])
    expect(result.outcomes).to eq([ older.id, newer.id ].sort => "judged: still_valid")
  end

  it "records each pair's outcome by its sorted ids: the verdict, or why it never reached the judge" do
    fs_project!("Legacy Gadget")
    named = fs_observe!(deployer, "Legacy Gadget is deployed by hand.", created_at: 2.days.ago)
    answers << [ verdict(older, "superseded") ]

    result = described_class.call([ pair(newer, older), pair(named, newer, distance: 0.1) ])

    expect(result.outcomes).to eq([ older.id, newer.id ].sort => "judged: superseded",
                                  [ named.id, newer.id ].sort => "kept: names another project (Legacy Gadget)")
    expect(result.leftovers).to be_empty
  end

  it "hands every pair back as a leftover while the judge LLM isn't usable" do
    AppSettings.enable_llm_summarization = false

    result = described_class.call([ pair ])

    expect(result).to have_attributes(items: [], judge_calls: 0, outcomes: {})
    expect(result.leftovers.map(&:observation_id_1)).to eq([ older.id ])
  end

  it "judges nothing with fact supersede off, but keeps the pairs as leftovers for when it's back on (Graphy, #172)" do
    AppSettings.fact_supersede_enabled = false
    answers << [ verdict(older, "superseded") ]

    result = described_class.call([ pair ])

    expect(result).to have_attributes(items: [], judge_calls: 0, outcomes: {})
    expect(result.leftovers.map { |left| [ left.observation_id_1, left.observation_id_2 ] }).to eq([ [ older.id, newer.id ] ])
    expect(bodies).to be_empty
  ensure
    AppSettings.where(var: "fact_supersede_enabled").delete_all
  end

  describe "through the scheduled stale scan", :with_test_embeddings do
    let(:service) { EmbeddingService.new(config: { url: "http://test", model: "test", provider: "ollama", dims: 768 }) }

    before do
      allow(AppSettings).to receive_messages(stale_memory_scan_enabled?: true, contradiction_detection_enabled?: true)
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:instance).and_return(service)
      allow(service).to receive(:embed).and_return(Array.new(768, 0.1))
      vector = ActiveRecord::Base.connection.quote("[#{Array.new(768, 0.1).join(',')}]")
      ActiveRecord::Base.connection.update(
        "UPDATE memory_observations SET embedding = VEC_FromText(#{vector}), embedded_at = NOW(6) WHERE id IN (#{older.id}, #{newer.id})"
      )
    end

    it "seeds a fact_supersede row with its own source, never a contradiction row" do
      answers << [ verdict(older, "superseded") ]

      expect { StaleMemoryScanJob.perform_now }.not_to change { MaintenanceReportRow.where(kind: "contradiction").count }

      row = MaintenanceReportRow.find_by!(kind: "fact_supersede")
      expect(row.payload).to include("fact_observation_id" => newer.id, "observation_id" => older.id, "origin" => described_class::ORIGIN)
      expect(row.maintenance_report.data).to include("source" => described_class::ORIGIN)
      expect(MaintenanceReport.where(report_type: "stale_memory_scan").last.data).to include("supersedes_seeded" => 1)
    end

    def scan_report = MaintenanceReport.where(report_type: "stale_memory_scan").order(:id).last

    # Review fix 1: the watermark moves on, so an unjudged pair is kept in the scan report and retried.
    it "retries a pair the judge couldn't take on the next scan, though nothing changed since" do
      AppSettings.enable_llm_summarization = false
      StaleMemoryScanJob.perform_now
      expect(MaintenanceReportRow.where(kind: "fact_supersede")).to be_empty
      expect(scan_report.data["fallback_retry"]).to eq([ [ older.id, newer.id ].sort + [ 0.0 ] ])

      AppSettings.enable_llm_summarization = true
      answers << [ verdict(older, "superseded") ]
      StaleMemoryScanJob.perform_now

      expect(MaintenanceReportRow.find_by!(kind: "fact_supersede").payload).to include("observation_id" => older.id)
      expect(scan_report.data["fallback_retry"]).to eq([])
    end

    # Review fix 2: an old contradiction row from the fallback is judged, not dismissed unseen.
    def old_fallback_row
      FactKeywords.compute!([ older, newer ])
      result = ContradictionDetector::Result.new(observation_id_1: older.id, observation_id_2: newer.id, distance: 0.08, confidence: 0.95)
      CompactionReviewService.seed_report(report_type: "compaction_review", source: "stale_memory_scan",
                                          items: [ ContradictionDetector.review_item(result) ]).sole
    end

    def quiet_scan
      # The pair's entity has no activity since the last scan: only the pending row brings it back.
      allow(StaleMemoryScanner).to receive(:previous_watermark).and_return(1.minute.from_now)
      StaleMemoryScanJob.perform_now
    end

    it "routes a pending fallback contradiction row through the judge and dismisses it, without suppression" do
      row = old_fallback_row
      answers << [ verdict(older, "superseded") ]

      quiet_scan

      expect(row.reload).to have_attributes(status: "dismissed", resolution_reason: "routed to Outdated by a fact (judged: superseded)")
      expect(MaintenanceReportSuppression.where(signature: row.signature)).to be_empty
      expect(MaintenanceReportRow.find_by!(kind: "fact_supersede").payload).to include("observation_id" => older.id, "origin" => described_class::ORIGIN)
      expect(scan_report.data).to include("contradictions_rerouted" => 1)
    end

    it "dismisses a rerouted row the judge found still valid, and leaves one it couldn't judge pending" do
      row = old_fallback_row
      AppSettings.enable_llm_summarization = false
      quiet_scan
      expect(row.reload.status).to eq("active")

      AppSettings.enable_llm_summarization = true
      answers << [ verdict(older, "still_valid") ]
      quiet_scan

      expect(row.reload).to have_attributes(status: "dismissed", resolution_reason: "routed to Outdated by a fact (judged: still_valid)")
      expect(MaintenanceReportRow.where(kind: "fact_supersede")).to be_empty
    end

    it "with fact supersede off: no judge call, no fallback row, and pending rows left alone" do
      AppSettings.fact_supersede_enabled = false
      row = old_fallback_row
      answers << [ verdict(older, "superseded") ]

      StaleMemoryScanJob.perform_now

      expect(bodies).to be_empty
      expect(MaintenanceReportRow.where(kind: "fact_supersede")).to be_empty
      expect(row.reload.status).to eq("active")
      expect(MaintenanceReportRow.where(kind: "contradiction").count).to eq(1)
    ensure
      AppSettings.where(var: "fact_supersede_enabled").delete_all
    end

    it "keeps the row through the review policies (its fact isn't a tagged source fact) and retires the older side on apply" do
      answers << [ verdict(older, "superseded") ]
      StaleMemoryScanJob.perform_now
      row = MaintenanceReportRow.find_by!(kind: "fact_supersede")

      ReviewPolicyRunner.call(trigger: "spec")
      expect(row.reload.status).to eq("active")

      result = CompactionReviewService.apply(row.row_uuid, { fact_action: "retire" })

      expect(result).to include(success: true, message: "Retired observation ##{older.id} (outdated by newer observation ##{newer.id})")
      expect(older.reload.status).not_to eq("active")
      expect(newer.reload.status).to eq("active")
    end
  end
end
