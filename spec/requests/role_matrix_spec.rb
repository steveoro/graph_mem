# frozen_string_literal: true

require "rails_helper"

# The guest guarantee (UI-1): walk every application route and check what a read-only
# guest, and a signed-out visitor, get. Deny by default: a route missing from
# guest_allowed must answer a guest with 403 and change nothing.
#
# The tables are block locals (not constants), so nothing leaks to Object.
RSpec.describe "Role matrix", type: :request do
  # "VERB /path" (dummy segments filled in) => expected guest status.
  guest_allowed = {
    "GET /search" => 200,
    "GET /graph" => 200,
    "GET /" => 302,
    "DELETE /operator/logout" => 302,
    "GET /operator/login" => 302, # a signed-in guest is sent on to /search
    "POST /operator/login" => 422, # exempt: a sign-in attempt (wrong password here)
    "POST /csp-reports" => 204,
    "GET /up" => 200
  }

  # Read endpoints a guest may call; a dummy id may 404, but never 401/403.
  guest_api_reads = ApiAuthentication::GUEST_READ_ACTIONS

  # Routes of Rails frameworks the app doesn't use (rails/all loads them). Their
  # controllers don't inherit ApplicationController, so the session never applies:
  # a guest gets exactly what an anonymous visitor gets.
  framework_prefixes = %w[active_storage/ action_mailbox/ rails/conductor/ turbo/native/]
  signed_out_open = [ "GET /operator/login", "POST /operator/login", "POST /csp-reports", "GET /up" ]

  route_case_class = Struct.new(:verb, :path, :action_key, :defined, keyword_init: true) do
    def key = "#{verb} #{path}"
    def api? = path.start_with?("/api/")
    def mutating? = verb != "GET"
  end

  route_cases = Rails.application.routes.routes.flat_map do |route|
    next [] unless route.dispatcher?

    controller = route.defaults[:controller].to_s
    next [] if framework_prefixes.any? { |prefix| controller.start_with?(prefix) }
    next [] if controller.start_with?("rails/") && controller != "rails/health"

    path = route.path.spec.to_s.gsub("(.:format)", "").gsub(/\([^)]*\)/, "").gsub(/[:*]\w+/, "1")
    # `resources` can declare routes (new, edit) whose controller has no such action.
    defined = "#{controller.camelize}Controller".constantize.action_methods.include?(route.defaults[:action].to_s)
    route.verb.to_s.split("|").map do |verb|
      route_case_class.new(verb: verb, path: path, action_key: "#{controller}##{route.defaults[:action]}", defined: defined)
    end
  end.uniq(&:key)

  # Mission Control's own routes (a mounted engine, so the walk above skips them). Its
  # controllers inherit Operator::JobsDashboardController < ApplicationController.
  jobs_cases = MissionControl::Jobs::Engine.routes.routes.flat_map do |route|
    path = "/operator/jobs#{route.path.spec.to_s.gsub("(.:format)", "").gsub(/[:*]\w+/, "1")}".chomp("/")
    route.verb.to_s.split("|").map { |verb| route_case_class.new(verb: verb, path: path, action_key: route.defaults[:controller]) }
  end.uniq(&:key)

  let!(:entity) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:project) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }

  before do
    MemoryObservation.create!(memory_entity: entity, content: "SynthWidget renders synthetic tiles.")
    MemoryRelation.create!(from_entity: entity, to_entity: project, relation_type: "part_of")
  end

  def record_counts
    [ MemoryEntity.count, MemoryObservation.count, MemoryRelation.count, AuditLog.count, MaintenanceReportRow.count ]
  end

  def perform(route_case)
    process route_case.verb.downcase.to_sym, route_case.path,
            params: (route_case.key == "POST /operator/login" ? { username: "guest", password: "wrong" } : {}),
            headers: (route_case.api? ? { "Accept" => "application/json" } : {})
  end

  it "covers the whole route table" do
    expect(route_cases.size).to be > 60
    expect(jobs_cases.size).to be > 20
  end

  it "lists only GET routes as guest API reads" do
    reads = route_cases.select { |route_case| guest_api_reads.include?(route_case.action_key) }
    expect(reads.map(&:action_key).uniq).to match_array(guest_api_reads)
    expect(reads).to all(have_attributes(verb: "GET"))
  end

  it "keeps the skipped framework routes outside ApplicationController" do
    Rails.application.routes.routes.select(&:dispatcher?).each do |route|
      controller = route.defaults[:controller].to_s
      next unless framework_prefixes.any? { |prefix| controller.start_with?(prefix) }

      expect("#{controller.camelize}Controller".constantize).not_to be <= ApplicationController
    end
  end

  context "as a guest" do
    before do
      enable_guest!
      sign_in_guest
      expect(response).to redirect_to(search_path)
    end

    route_cases.each do |route_case|
      it "#{route_case.key} (#{route_case.action_key})" do
        counts = record_counts

        perform(route_case)

        if !route_case.defined
          expect(response).to have_http_status(:not_found)
        elsif guest_allowed.key?(route_case.key)
          expect(response.status).to eq(guest_allowed[route_case.key])
        elsif guest_api_reads.include?(route_case.action_key)
          expect(response.status).not_to be_in([ 401, 403 ])
        else
          expect(response).to have_http_status(:forbidden)
          if route_case.api?
            expect(response.parsed_body).to eq("error" => "forbidden", "role" => "guest")
          else
            expect(response.body).to include('data-testid="guest-forbidden"')
          end
          expect(record_counts).to eq(counts) if route_case.mutating?
        end
      end
    end

    it "redirects / to /search and logout to the login page" do
      get root_path
      expect(response).to redirect_to(search_path)

      delete operator_logout_path
      expect(response).to redirect_to(operator_login_path)
    end

    jobs_cases.each do |route_case|
      it "Mission Control #{route_case.key} (#{route_case.action_key}) is 403" do
        perform(route_case)

        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include('data-testid="guest-forbidden"')
      end
    end

    it "gets 404 from /api-docs" do
      get "/api-docs/index.html"
      expect(response).to have_http_status(:not_found)
    end
  end

  context "when signed out" do
    route_cases.reject { |route_case| signed_out_open.include?(route_case.key) }.each do |route_case|
      it "#{route_case.key} needs a sign-in" do
        perform(route_case)

        if !route_case.defined
          expect(response).to have_http_status(:not_found)
        elsif route_case.api?
          expect(response).to have_http_status(:unauthorized)
        else
          expect(response).to redirect_to(operator_login_path)
        end
      end
    end
  end

  context "as the operator" do
    before { sign_in_operator }

    it "reaches Mission Control and /api-docs" do
      get "/operator/jobs"
      expect(response).to have_http_status(:ok)

      get "/api-docs/index.html"
      expect(response).to have_http_status(:ok)
    end
  end
end
