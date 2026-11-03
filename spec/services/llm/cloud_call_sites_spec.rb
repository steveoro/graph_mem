# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR2, step A3: the three call sites through a FakeProvider(cloud: true) that echoes the
# tokens it was sent. No canary, in any variant, reaches a prompt; callers get the originals back;
# the gate refuses without a provider call. Canaries are synthetic (`Zq7…`, `.example` hosts) and
# the secret is random.
RSpec.describe "Cloud calls at the call sites" do
  let!(:project) { MemoryEntity.create!(name: "Zq7Canary Project", entity_type: "Project", aliases: "Zq7cp") }
  let!(:widget) { MemoryEntity.create!(name: "Zq7CanaryWidget", entity_type: "Component", project_id: project.id) }
  let!(:service) { MemoryEntity.create!(name: "Zq7 Alpha Service", entity_type: "Service", project_id: project.id) }
  let(:secret) { "sk-#{SecureRandom.alphanumeric(40)}" }
  let(:canary_text) do
    "Zq7CanaryWidget calls Zq7 Alpha Service for Zq7cp at https://git.zq7canary.example/org/repo.git, build.zq7canary.internal " \
      "and 10.7.7.7; logs in /home/zq7user/zq7canary_project/log; ask ops@zq7canary.example; key #{secret}."
  end

  # Fails on any canary left in any prompt the fake received, in any spelling.
  def expect_no_canary(fake)
    expect(fake.calls).not_to be_empty
    fake.calls.each do |call|
      folded = call.prompt.downcase.gsub(/[^a-z0-9]/, "")
      expect(folded).not_to include("zq7canary", "zq7cp", "zq7user", "zq7alpha")
      expect(call.prompt).not_to include("10.7.7.7", secret)
    end
  end

  def first_token(text, type) = text[/⟦#{type}_\h+⟧/]

  describe "summary" do
    before do
      MemoryObservation.create!(memory_entity: widget, content: canary_text)
      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [ HybridSearchStrategy::SearchResult.new(entity: widget, score: 0.9, matched_fields: [ "name" ]) ])
      )
    end

    let(:fake) do
      FakeProvider.new(cloud: true) { |text, **| { ok: true, text: "#{first_token(text, 'ENT')} uses #{first_token(text, 'URL')}.", error: nil, latency_ms: 1.0 } }
    end

    it "masks every canary and restores the summary" do
      project.update!(cloud_allowed: true)

      response = with_llm_provider(fake) { SummarizerService.call(query: "Zq7CanaryWidget at Zq7cp") }

      expect_no_canary(fake)
      expect(response).to include(generation_mode: "llm", summary: "Zq7CanaryWidget uses https://git.zq7canary.example/org/repo.git.")
    end

    it "is refused (fallback_reason cloud_not_allowed) by default, and when any project in the evidence doesn't allow it" do
      expect(with_llm_provider(fake) { SummarizerService.call(query: "Zq7CanaryWidget") }).to include(generation_mode: "deterministic", fallback_reason: "cloud_not_allowed")

      project.update!(cloud_allowed: true)
      other = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
      gizmo = MemoryEntity.create!(name: "Gadget Gizmo", entity_type: "Component", project_id: other.id)
      MemoryObservation.create!(memory_entity: gizmo, content: "Gadget Gizmo ships.")
      results = [ widget, gizmo ].map { |entity| HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.9, matched_fields: [ "name" ]) }
      allow(HybridSearchStrategy).to receive(:new).and_return(instance_double(HybridSearchStrategy, search: results))

      expect(with_llm_provider(fake) { SummarizerService.call(query: "Zq7CanaryWidget") }).to include(fallback_reason: "cloud_not_allowed")
      expect(fake.calls).to be_empty
    end
  end

  describe "scan" do
    around do |example|
      Dir.mktmpdir("llm_cloud_scan") do |dir|
        @root = File.realpath(dir)
        example.run
      end
    end

    before do
      write("Gemfile", "gem \"zq7canary-widget\"\n")
      write("lib/zq7canary_widget/zq7_canary_widget.rb",
            "# Zq7Canary Project, ask ops@zq7canary.example\nclass Zq7CanaryWidget\n  ZQ7_CANARY_WIDGET_URL = \"https://git.zq7canary.example/org/repo.git\"\n" \
            "  def zq7_canary_widget = Zq7CanaryWidgets.new\nend\n" + ("# Zq7CanaryWidget renders frames.\n" * 110))
      write("config/zq7canary.yml", "host: build.zq7canary.internal\nip: 10.7.7.7\nlog: /home/zq7user/zq7canary_project/log\ntoken: #{secret}\n" +
                                    ("note: Zq7 Alpha Service serves zq7-canary-widget\n" * 90))
      AppSettings.summary_num_ctx = 4096
      AppSettings.project_scan_chunk_output_tokens = 512
      AppSettings.clear_cache
    end

    after { %w[summary_num_ctx project_scan_chunk_output_tokens].each { |var| AppSettings.where(var: var).delete_all } }

    def write(relative, content)
      FileUtils.mkdir_p(File.dirname(File.join(@root, relative)))
      File.write(File.join(@root, relative), content)
    end

    def scan = ProjectScanner.new(project_root: @root, project_name: "Zq7Canary Project", mode: "rescan", file_globs: %w[Gemfile lib/**/*.rb config/*.yml]).call

    # Names the class it was sent (part 1), else the first name already found (later parts); the
    # second part's first try is refused with 413, so it is split.
    let(:fake) do
      tries = Hash.new(0)
      FakeProvider.new(cloud: true) do |text, **|
        part = text[/This is part (\d+) of/, 1]
        next({ ok: false, text: nil, error: "provider_unavailable", latency_ms: 1.0, http_status: 413 }) if part == "2" && (tries[part] += 1) == 1

        name = text[/class (⟦ENT_\h+⟧)/, 1] || text[/already found[^:]*: (⟦ENT_\h+⟧)/, 1]
        item = { entity: { name: name, type: "Component" }, observations: [ "#{name} is in #{first_token(text, 'PRJ')}." ],
                 relations: [ { to: first_token(text, "PRJ"), type: "part_of", confidence: 0.9 } ] }
        { ok: true, text: { architecture: [ item ] }.to_json, error: nil, latency_ms: 1.0, done_reason: "stop", prompt_tokens: 10 }
      end
    end

    it "masks every canary in code, paths, the Gemfile and config, keeps one mapping across parts and splits, and restores the result" do
      project.update!(cloud_allowed: true)

      result = with_llm_provider(fake) { scan }

      expect_no_canary(fake)
      expect(result).to have_attributes(success: true, fallback: false, parts_failed: 0)
      prompts = fake.calls.map(&:prompt)
      expect(prompts.join).to include("(half 1 of 2)", "(half 2 of 2)")
      class_token = prompts.filter_map { |prompt| prompt[/class (⟦ENT_\h+⟧)/, 1] }.first
      names = prompts.filter_map { |prompt| prompt[/already found[^:]*: (⟦ENT_\h+⟧)/, 1] }
      expect(names).to be_present.and(all(eq(class_token)))
      expect(widget.memory_observations.pluck(:content)).to include("Zq7CanaryWidget is in Zq7Canary Project.")

      first_scan = fake.calls.map(&:prompt).join
      with_llm_provider(fake) { scan }
      expect(fake.calls.last.prompt).not_to include(class_token)
      expect(first_scan).to include(class_token)
    end

    it "falls back to the deterministic extraction by default, and refuses the next part when the flag goes off mid-scan" do
      expect(with_llm_provider(fake) { scan }).to have_attributes(fallback: true)
      expect(fake.calls).to be_empty

      project.update!(cloud_allowed: true)
      switch_off = FakeProvider.new(cloud: true) do |text, **|
        project.update!(cloud_allowed: false)
        fake.generate(text, style: "concise")
      end
      result = with_llm_provider(switch_off) { scan }
      expect(switch_off.calls.size).to eq(1)
      expect(result).to have_attributes(partial: true)
    end
  end

  describe "judge" do
    let!(:old) { fs_observe!(widget, "Zq7CanaryWidget runs on fast-mcp at build.zq7canary.internal (#{secret}).") }
    let!(:fact) { fs_fact!(project, "Zq7Canary Project uses the mcp gem; ask ops@zq7canary.example.", tags: [ "replaces:fast-mcp" ]) }
    let(:fake) do
      FakeProvider.new(cloud: true) do |text, **|
        id = text[/"id":(\d+),"text"/, 1].to_i
        reason = "#{first_token(text, 'PRJ')} moved #{first_token(text, 'ENT')} off #{first_token(text, 'HOST')}"
        { ok: true, text: [ { id: id, verdict: "superseded", confidence: 0.9, reason: reason } ].to_json, error: nil, latency_ms: 1.0 }
      end
    end

    def judge(candidates = nil)
      candidates ||= FactSupersede::LegacyGuard.new(fact).apply(FactSupersede::Candidates.call(fact).candidates)
      with_llm_provider(fake) { FactSupersede::Judge.call(fact, candidates) }
    end

    it "masks every canary and restores the reason" do
      project.update!(cloud_allowed: true)

      verdict = judge.sole

      expect_no_canary(fake)
      expect(verdict).to have_attributes(verdict: "superseded", judged: true, reason: "Zq7Canary Project moved Zq7CanaryWidget off build.zq7canary.internal")
    end

    it "returns unjudged by default, and when a candidate has no project" do
      expect(judge.map(&:verdict)).to eq([ "unjudged" ])

      project.update!(cloud_allowed: true)
      loose = fs_observe!(MemoryEntity.create!(name: "Alpha Service", entity_type: "Service"), "fast-mcp is pinned.")
      candidate = FactSupersede::Candidate.new(observation: loose, score: 0.6, scoped: false)
      expect(judge([ candidate ]).map(&:verdict)).to eq([ "unjudged" ])
      expect(fake.calls).to be_empty
    end
  end
end
