# frozen_string_literal: true

require "rails_helper"

# UI-5b B2: Settings › Review policies (operator only, validated, audited).
RSpec.describe "Settings › Review policies", type: :request do
  def save(tab: "review_policies", **settings)
    patch system_settings_path, params: { tab: tab, settings: settings.transform_keys(&:to_s) }
  end

  context "as the operator" do
    before { sign_in_operator }

    it "starts with both auto-apply toggles off and the hygiene policies on" do
      get system_settings_path(tab: "review_policies")

      expect(response).to have_http_status(:ok)
      body = Nokogiri::HTML(response.body)
      checked = ->(key) { body.at_css("input[type=checkbox][data-testid='setting-#{key}']")["checked"].present? }
      expect(checked.call("enable_auto_apply_relationships")).to be(false)
      expect(checked.call("enable_auto_apply_expired_validity")).to be(false)
      expect(checked.call("enable_review_policy_dangling")).to be(true)
    end

    it "toggles each policy independently" do
      save("enable_auto_apply_relationships" => "1", "enable_auto_apply_expired_validity" => "0")

      expect(response).to redirect_to(system_settings_path(tab: "review_policies"))
      expect(AppSettings.review_policy_enabled?(:auto_apply_relationships)).to be(true)
      expect(AppSettings.review_policy_enabled?(:auto_apply_expired_validity)).to be(false)
    end

    it "refuses an out-of-range threshold with 422 and saves nothing" do
      %w[0.79 1.01 abc].each do |value|
        save("auto_apply_relationship_min_confidence" => value, "enable_auto_apply_relationships" => "1")

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("must be between 0.8 and 1.0")
      end
      expect(AppSettings.review_policy_enabled?(:auto_apply_relationships)).to be(false)
      expect(AuditLog.where(auditable_type: "AppSettings")).not_to exist
    end

    it "saves an in-range threshold that the next policy run uses" do
      save("auto_apply_relationship_min_confidence" => "0.85")

      expect(AppSettings.review_number(:auto_apply_relationship_min_confidence)).to eq(0.85)
    end

    it "ignores review settings posted under another tab (only the posted group is saved)" do
      save(tab: "telemetry", "review_backlog_ceiling" => "10", "tool_invocation_retention_days" => "40")

      expect(response).to redirect_to(system_settings_path(tab: "telemetry"))
      expect(AppSettings.review_number(:review_backlog_ceiling)).to eq(300)
      expect(AppSettings.uncached_string("tool_invocation_retention_days")).to eq("40")
    end

    it "writes one audit row per changed key, shown on the audit log page" do
      save("enable_auto_apply_relationships" => "1", "review_attention_threshold" => "55", "enable_review_policy_dangling" => "1")

      logs = AuditLog.where(auditable_type: "AppSettings").order(:id)
      expect(logs.map { |log| log.changed_fields.keys.sole }).to contain_exactly("enable_auto_apply_relationships", "review_attention_threshold")
      expect(logs.find { |log| log.changed_fields.key?("review_attention_threshold") }.changed_fields)
        .to eq("review_attention_threshold" => { "from" => 40, "to" => 55 })
      expect(logs.map(&:actor)).to all(start_with("operator:"))

      get system_audit_log_path(auditable_type: "AppSettings")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("AppSettings##{logs.first.auditable_id}", "enable_auto_apply_relationships")
    end
  end

  it "answers a guest with 403 and changes nothing" do
    enable_guest!
    sign_in_guest

    get system_settings_path(tab: "review_policies")
    expect(response).to have_http_status(:forbidden)
    save("enable_auto_apply_relationships" => "1")
    expect(response).to have_http_status(:forbidden)
    expect(AppSettings.review_policy_enabled?(:auto_apply_relationships)).to be(false)
  end

  it "sends a signed-out visitor to the sign-in page" do
    get system_settings_path(tab: "review_policies")

    expect(response).to redirect_to(operator_login_path)
  end
end
