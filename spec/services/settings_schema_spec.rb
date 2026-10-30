# frozen_string_literal: true

require "rails_helper"

# UI-7 S2: one schema for every AppSettings field. The validators are the old
# Operator::SettingsController checks, moved without changing what they accept.
RSpec.describe SettingsSchema do
  let(:keys_in_groups) { described_class.groups.flat_map { |group| group.fields.map(&:key) } }

  it "puts every AppSettings field in exactly one group, or in LEGACY_KEYS" do
    defined = AppSettings.defined_fields.map { |field| field[:key].to_s }

    expect(keys_in_groups.tally.select { |_key, count| count > 1 }).to be_empty
    expect(keys_in_groups + described_class::LEGACY_KEYS).to match_array(defined)
    expect(keys_in_groups).to include("enable_contradiction_detection", "project_scan_validation_batch_size")
    expect(keys_in_groups & described_class::LEGACY_KEYS).to be_empty
  end

  it "gives every field a label and help, and every group a title" do
    described_class.groups.each do |group|
      expect(I18n.exists?(group.title)).to be(true), group.title
      group.fields.each do |field|
        expect(I18n.exists?(field.label)).to be(true), field.label
        expect(I18n.exists?(field.help)).to be(true), field.help
      end
    end
  end

  it "places the groups on Settings, Backups and Access" do
    expect(described_class.groups(page: :backups).map(&:key)).to eq([ :backups ])
    expect(described_class.groups(page: :access).map(&:key)).to eq([ :access ])
    expect(described_class.group(:access).writable_keys).to eq(%w[enable_guest_access] + McpAccessSettings::KEYS)
    expect(described_class.group(:feature_flags).writable_keys).not_to include("enable_guest_access")
    expect(described_class.groups.map(&:page).uniq).to match_array(described_class::PAGES)
  end

  it "never writes a read-only field" do
    expect(described_class.group(:backups).writable_keys).not_to include("backup_schedule_cron")
    expect(described_class.group(:embeddings).writable_keys).not_to include("embedding_backfill_schedule_cron")
  end

  it "reads the accepted ranges from AppSettings' validates" do
    expect(described_class.field("backup_keep_max").range).to eq(1..100)
    expect(described_class.field("auto_apply_relationship_min_confidence").range).to eq(0.8..1.0)
    expect(described_class.field("embedding_dims").range).to be_nil
  end

  describe ".errors" do
    def errors(group, posted)
      described_class.errors(described_class.group(group), posted)
    end

    it "refuses the embedding values the controller refused" do
      expect(errors(:embeddings, "embedding_provider" => "bogus")).to include("embedding_provider" => /Invalid embedding provider/)
      expect(errors(:embeddings, "embedding_dims" => "5000")).to include("embedding_dims" => /Dimensions must be 0/)
      expect(errors(:embeddings, "embedding_url" => "ftp://x")).to include("embedding_url" => /valid http or https URL/)
      expect(errors(:embeddings, "embedding_provider" => "", "embedding_dims" => "0", "embedding_url" => "")).to be_empty
      expect(errors(:embeddings, "embedding_provider" => "ollama", "embedding_dims" => "768", "embedding_url" => "http://127.0.0.1:9")).to be_empty
    end

    it "refuses the summary values the controller refused" do
      expect(errors(:summaries, "summary_provider" => "bogus")).to include("summary_provider" => /Invalid summary provider/)
      expect(errors(:summaries, "summary_timeout" => "301")).to include("summary_timeout" => /Timeout must be 0/)
      expect(errors(:summaries, "summary_max_tokens" => "8")).to include("summary_max_tokens" => /Max tokens must be 0/)
      expect(errors(:summaries, "summary_num_ctx" => "1024")).to include("summary_num_ctx" => /between 2048 and 131072/)
      expect(errors(:summaries, "summary_num_ctx" => "200000")).to include("summary_num_ctx" => /between 2048 and 131072/)
      expect(errors(:summaries, "summary_num_ctx" => "0")).to be_empty
      expect(errors(:summaries, "summary_num_ctx" => "8192")).to be_empty
      expect(errors(:summaries, "summary_observations_per_entity" => "101")).to include("summary_observations_per_entity" => /between 0 and 100/)
      expect(errors(:summaries, "summary_observations_per_entity" => "-1")).to include("summary_observations_per_entity" => /between 0 and 100/)
      expect(errors(:summaries, "summary_url" => "not a url")).to include("summary_url" => /valid http or https URL/)
      expect(errors(:summaries, "summary_timeout" => "0", "summary_max_tokens" => "16", "summary_observations_per_entity" => "")).to be_empty
    end

    it "keeps the import distance between 0.20 and 0.50, posted or not" do
      expect(errors(:imports, "import_observation_duplicate_max_distance" => "0.6")).to include("import_observation_duplicate_max_distance" => /0.20 and 0.50/)
      expect(errors(:imports, {})).to include("import_observation_duplicate_max_distance" => /0.20 and 0.50/)
      expect(errors(:imports, "import_observation_duplicate_max_distance" => "0.35")).to be_empty
    end

    it "checks AppSettings' ranges" do
      expect(errors(:backups, "backup_keep_max" => "0")).to include("backup_keep_max" => /between 1 and 100 \(got 0\)/)
      expect(errors(:telemetry, "tool_invocation_retention_days" => "4000")).to include("tool_invocation_retention_days")
      expect(errors(:review_policies, "review_attention_threshold" => "0")).to include("review_attention_threshold")
      expect(errors(:backups, "backup_keep_max" => "10")).to be_empty
    end

    it "normalizes the subfolder filter in place and refuses bad entries" do
      with_scan_home do |home|
        posted = { "project_scan_subfolders" => "#{home}/Projects, work/clients" }
        expect(errors(:project_scans, posted)).to be_empty
        expect(posted["project_scan_subfolders"]).to eq("Projects, work/clients")

        expect(errors(:project_scans, "project_scan_subfolders" => "../x, .ssh"))
          .to include("project_scan_subfolders" => a_string_including("../x contains", ".ssh is inside a hidden"))
        expect(errors(:project_scans, {})).to be_empty
      end
    end
  end

  describe ".cast" do
    it "converts posted values as the controller did" do
      expect(described_class.cast(described_class.field("enable_garbage_collector"), "1")).to be(true)
      expect(described_class.cast(described_class.field("enable_garbage_collector"), "0")).to be(false)
      expect(described_class.cast(described_class.field("backup_keep_max"), "12")).to eq(12)
      expect(described_class.cast(described_class.field("auto_apply_relationship_min_confidence"), "0.95")).to eq(0.95)
      expect(described_class.cast(described_class.field("summary_model"), "  qwen3:8b ")).to eq("qwen3:8b")
      expect(described_class.cast(described_class.field("embedding_model"), " nomic ")).to eq(" nomic ")
    end
  end
end
