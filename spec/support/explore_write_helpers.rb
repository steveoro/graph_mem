# frozen_string_literal: true

# Request-spec helpers for Explore's write endpoints (UI-4b): Turbo Stream headers, the streams
# in a response, and the shared guest / CSRF guarantees every write controller must keep.
module ExploreWriteHelpers
  STREAM = { "Accept" => "text/vnd.turbo-stream.html, text/html" }.freeze

  def stream_headers = STREAM

  # @return [Nokogiri::XML::Element, nil] the <turbo-stream> for `action` (and `target`)
  def turbo_stream_for(action, target = nil)
    selector = "turbo-stream[action='#{action}']"
    selector += "[target='#{target}']" if target
    Nokogiri::HTML(response.body).at_css(selector)
  end

  def toast_text = turbo_stream_for("update", "toasts")&.text.to_s.squish

  # @return [Hash, nil] the graph_changed payload ({ "removed" => [...], "changed" => [...] })
  def graph_changed_payload
    stream = turbo_stream_for("graph_changed")
    stream && JSON.parse(stream.at_css("template").text)
  end

  def explore_record_counts
    [ MemoryEntity.count, MemoryObservation.count, MemoryRelation.count, ChangeSet.count, AuditLog.count,
      MaintenanceReportRow.count ]
  end
end

# Every Explore write route: 403 for a guest and 422 without a CSRF token, nothing written either way.
# `request` is a lambda run in the example: it performs the write.
RSpec.shared_examples "an operator-only Explore write" do |request|
  it "answers 403 to a guest and writes nothing" do
    enable_guest!
    sign_in_guest
    before_counts = explore_record_counts

    instance_exec(&request)

    expect(response).to have_http_status(:forbidden)
    expect(explore_record_counts).to eq(before_counts)
  end

  it "refuses the operator without a CSRF token and writes nothing" do
    sign_in_operator
    ActionController::Base.allow_forgery_protection = true
    before_counts = explore_record_counts

    instance_exec(&request)

    expect(response).to have_http_status(:unprocessable_content)
    expect(explore_record_counts).to eq(before_counts)
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end

RSpec.configure { |config| config.include ExploreWriteHelpers, type: :request }
