# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppSettings, type: :model do
  before { AppSettings.clear_cache }

  describe "field definitions" do
    it "defines feature flag fields" do
      expect(AppSettings).to respond_to(:enable_dream_state_compactor)
      expect(AppSettings).to respond_to(:enable_garbage_collector)
    end

    it "defines database backup fields" do
      expect(AppSettings).to respond_to(:backup_folder_path)
      expect(AppSettings).to respond_to(:backup_keep_max)
      expect(AppSettings).to respond_to(:backup_schedule_cron)
      expect(AppSettings).to respond_to(:enable_scheduled_backups)
    end

    it "defines summarization fields" do
      expect(AppSettings).to respond_to(:summary_url)
      expect(AppSettings).to respond_to(:summary_model)
      expect(AppSettings).to respond_to(:summary_provider)
      expect(AppSettings).to respond_to(:summary_timeout)
      expect(AppSettings).to respond_to(:summary_max_tokens)
      expect(AppSettings).to respond_to(:summary_observations_per_entity)
      expect(AppSettings).to respond_to(:enable_llm_summarization)
    end

    it "defines the import observation duplicate distance" do
      expect(AppSettings).to respond_to(:import_observation_duplicate_max_distance)
    end

    it "defines the project scan subfolder filter" do
      expect(AppSettings).to respond_to(:project_scan_subfolders)
      expect(AppSettings).to respond_to(:project_scan_root_paths)
    end
  end

  describe "summarization defaults" do
    it "disables LLM summarization by default" do
      expect(AppSettings.enable_llm_summarization).to be false
    end
  end

  describe ".llm_summarization_enabled?" do
    it "reads directly from the database" do
      AppSettings.enable_llm_summarization = true
      expect(AppSettings.llm_summarization_enabled?).to be true
    end
  end

  describe "default values" do
    it "enables maintenance features by default" do
      expect(AppSettings.enable_dream_state_compactor).to be true
      expect(AppSettings.enable_garbage_collector).to be true
    end

    it "has conservative backup defaults" do
      expect(AppSettings.backup_folder_path).to eq("db/backup")
      expect(AppSettings.backup_keep_max).to eq(10)
      expect(AppSettings.enable_scheduled_backups).to be false
    end

    it "uses a balanced import observation duplicate distance" do
      expect(AppSettings.import_observation_duplicate_max_distance).to eq(0.35)
    end

    it "defaults the subfolder filter to Projects" do
      expect(AppSettings.project_scan_subfolders).to eq("Projects")
      expect(AppSettings.project_scan_subfolders_raw).to eq("Projects")
    end

    it "delegates project_scan_root_paths to the scan policy" do
      with_scan_home do |home|
        expect(AppSettings.project_scan_root_paths).to eq([ File.join(home, "Projects") ])
      end
    end

    it "reports a stored legacy project_scan_roots value, which is ignored" do
      expect(AppSettings.legacy_project_scan_roots).to be_nil

      AppSettings.project_scan_roots = "/srv/code"

      expect(AppSettings.legacy_project_scan_roots).to eq("/srv/code")
    end
  end

  describe ".scheduled_backups_enabled?" do
    it "returns true when enabled" do
      AppSettings.enable_scheduled_backups = true
      expect(AppSettings.scheduled_backups_enabled?).to be true
    end

    it "returns false when disabled" do
      AppSettings.enable_scheduled_backups = false
      expect(AppSettings.scheduled_backups_enabled?).to be false
    end

    it "reads directly from the database" do
      AppSettings.enable_scheduled_backups = true
      expect(AppSettings).to receive(:connection).and_call_original
      AppSettings.scheduled_backups_enabled?
    end
  end

  describe ".dream_state_compactor_enabled?" do
    it "defaults to true when unset" do
      AppSettings.where(var: "enable_dream_state_compactor").delete_all
      expect(AppSettings.dream_state_compactor_enabled?).to be true
    end
  end

  describe ".garbage_collector_enabled?" do
    it "defaults to true when unset" do
      AppSettings.where(var: "enable_garbage_collector").delete_all
      expect(AppSettings.garbage_collector_enabled?).to be true
    end
  end

  describe ".backup_schedule_cron" do
    it "reads DatabaseBackupJob schedules from recurring.yml" do
      expect(AppSettings.backup_schedule_cron).to be_a(String)
      expect(AppSettings.backup_schedule_cron).not_to eq("")
    end
  end

  describe ".backup_config" do
    it "returns a configuration hash" do
      AppSettings.backup_folder_path = "tmp/backups"
      AppSettings.backup_keep_max = 5
      AppSettings.enable_scheduled_backups = true

      config = AppSettings.backup_config

      expect(config[:folder_path]).to eq("tmp/backups")
      expect(config[:keep_max]).to eq(5)
      expect(config[:enabled]).to be true
      expect(config[:schedule_cron]).to be_a(String)
    end
  end
  describe "review policy settings (UI-5a)" do
    def write_past_validation(var, value)
      setting = described_class.find_or_initialize_by(var: var)
      setting.value = value
      setting.save!(validate: false)
    end

    it "defaults to the hygiene policies on and both auto-apply toggles off" do
      expect(described_class.review_policy_enabled?(:dangling)).to be(true)
      expect(described_class.review_policy_enabled?(:no_longer_flagged)).to be(true)
      expect(described_class.review_policy_enabled?(:expire_low_confidence)).to be(true)
      expect(described_class.review_policy_enabled?(:auto_apply_relationships)).to be(false)
      expect(described_class.review_policy_enabled?(:auto_apply_expired_validity)).to be(false)
      expect(described_class::REVIEW_NUMBERS.keys.map { |name| described_class.review_number(name) }).to eq([ 300, 40, 30, 0.9, 0.45 ])
    end

    it "clamps numbers written past validation to their range" do
      write_past_validation("auto_apply_relationship_min_confidence", 0.5)
      write_past_validation("review_attention_threshold", 500)
      write_past_validation("review_expire_low_confidence_days", "soon")

      expect(described_class.review_number(:auto_apply_relationship_min_confidence)).to eq(0.8)
      expect(described_class.review_number(:review_attention_threshold)).to eq(100)
      expect(described_class.review_number(:review_expire_low_confidence_days)).to eq(30)
    end

    it "validates the ranges on a normal save" do
      expect { described_class.auto_apply_relationship_min_confidence = 1.01 }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
