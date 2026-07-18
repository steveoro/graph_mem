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
end
