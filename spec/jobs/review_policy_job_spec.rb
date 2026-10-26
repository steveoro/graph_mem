# frozen_string_literal: true

require "rails_helper"
require "fugit"

RSpec.describe ReviewPolicyJob, type: :job do
  include ActiveJob::TestHelper

  it "runs the policies and writes a review_policy_run report" do
    expect { described_class.perform_now(trigger: "nightly") }.to change { MaintenanceReport.by_type("review_policy_run").count }.by(1)
    expect(MaintenanceReport.by_type("review_policy_run").last.data["trigger"]).to eq("nightly")
  end

  # A separate session (transactional tests share one pooled connection, and GET_LOCK is
  # re-entrant within a session).
  it "never overlaps a run already holding the lock" do
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    holder = Mysql2::Client.new(**config.slice(:host, :port, :socket, :username, :password, :database))
    holder.query("SELECT GET_LOCK('#{described_class::LOCK_PREFIX}:#{config[:database]}', 0)")

    expect(described_class.perform_now).to be_nil
    expect(MaintenanceReport.by_type("review_policy_run")).not_to exist
  ensure
    holder&.close
  end

  it "is enqueued only when rows were seeded" do
    expect { described_class.enqueue_if_seeded(trigger: "stale_scan", seeded: []) }.not_to have_enqueued_job(described_class)
    expect { described_class.enqueue_if_seeded(trigger: "stale_scan", seeded: 0) }.not_to have_enqueued_job(described_class)
    expect { described_class.enqueue_if_seeded(trigger: "compaction", seeded: false) }.not_to have_enqueued_job(described_class)
    expect { described_class.enqueue_if_seeded(trigger: "project_scan", seeded: [ :row ]) }
      .to have_enqueued_job(described_class).with(trigger: "project_scan")
  end

  it "is enqueued after a stale scan that seeded rows, and not after one that seeded none" do
    allow(AppSettings).to receive(:stale_memory_scan_enabled?).and_return(true)
    allow(StaleMemoryScanner).to receive(:scan).and_return(items: [], contradiction_items: [], next_watermark: Time.current)
    expect { StaleMemoryScanJob.perform_now }.not_to have_enqueued_job(described_class)

    entity = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
    observation = MemoryObservation.create!(memory_entity: entity, content: "SynthWidget expired.", valid_until: 1.day.ago)
    item = StaleMemoryScanner.item(entity.id, entity.name, [ observation ], signal: "valid_until_elapsed", reason: "synthetic")
    allow(StaleMemoryScanner).to receive(:scan).and_return(items: [ item ], contradiction_items: [], next_watermark: Time.current)
    expect { StaleMemoryScanJob.perform_now }.to have_enqueued_job(described_class).with(trigger: "stale_scan")
  end

  it "is scheduled nightly in development and production" do
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"))

    %w[development production].each do |env|
      config = recurring.dig(env, "review_policy")
      expect(config).to include("class" => "ReviewPolicyJob", "queue" => "low_priority")
      expect(Fugit.parse(config["schedule"], multi: :fail)).to be_a(Fugit::Cron)
    end
  end
end
