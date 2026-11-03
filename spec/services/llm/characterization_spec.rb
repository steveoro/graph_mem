# frozen_string_literal: true

require "rails_helper"

# Agent-CLI train PR1, step P0: what every LLM call sends today, pinned before the provider
# abstraction (Llm::Router) goes in front of it. Each example drives a real call path with
# Net::HTTP stubbed, and compares the prompt with a golden file in spec/fixtures/llm/ and the rest
# of the request body with a literal Hash, under both transports. Database ids are replaced by
# placeholders (OBS1, ENT1, …) before comparing. These goldens must not change in this train
# unless a plan says so.
RSpec.describe "LLM calls (characterization)" do
  let(:bodies) { [] }
  let(:read_timeouts) { [] }
  let(:results) { [] }
  # Answers sent back, in order; each is the model's text.
  let(:answers) { [] }

  def golden(name) = Rails.root.join("spec/fixtures/llm/#{name}.txt").read

  def use_provider(provider)
    AppSettings.enable_llm_summarization = true
    AppSettings.summary_url = "http://summary.test:11434"
    AppSettings.summary_model = "synth-model"
    AppSettings.summary_provider = provider
    AppSettings.clear_cache
    SummaryGenerationClient.reset_instance!
    @provider = provider
  end

  # The provider's answer body for `text`, in the shape of the configured transport.
  def answer_body(text)
    if @provider == "openai_compatible"
      { choices: [ { message: { content: text }, finish_reason: "stop" } ], usage: { prompt_tokens: 321 } }
    else
      { response: text, prompt_eval_count: 321, done_reason: "stop" }
    end
  end

  before do
    http = instance_double(Net::HTTP, "use_ssl=": nil, "open_timeout=": nil)
    allow(http).to receive(:read_timeout=) { |seconds| read_timeouts << seconds }
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:request) do |request|
      bodies << JSON.parse(request.body)
      response = instance_double(Net::HTTPSuccess, body: answer_body(answers.shift.to_s).to_json)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      response
    end
    allow(SummaryGenerationClient).to receive(:generate).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |result| results << result }
    end
  end

  after do
    %w[enable_llm_summarization summary_url summary_model summary_provider summary_num_ctx project_scan_chunk_output_tokens]
      .each { |var| AppSettings.where(var: var).delete_all }
    AppSettings.clear_cache
    SummaryGenerationClient.reset_instance!
  end

  # The prompt sent in a captured body, under either transport.
  def prompt_of(body)
    @provider == "openai_compatible" ? body.dig("messages", 1, "content") : body["prompt"]
  end

  # The body without its prompt.
  def envelope_of(body)
    return body.except("prompt") unless @provider == "openai_compatible"

    body.merge("messages" => [ body["messages"][0], body["messages"][1].merge("content" => "PROMPT") ])
  end

  # @param ids [Hash{String => String}] literal text => its placeholder
  def placeholders(text, ids)
    ids.reduce(text) { |memo, (literal, label)| memo.gsub(literal, label) }
  end

  let(:concise_system) { "Summarize only the supplied observations. Do not invent facts. Preserve uncertainty and conflicting statements." }

  describe "G1/G2: SummarizerService (summarize tool, POST /api/v1/summaries)" do
    let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", description: "Renders gadgets") }
    let!(:first) { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders gadget frames.", confidence: 0.9) }
    let!(:second) { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget caches frames in Alpha Service.", confidence: 0.6) }

    before do
      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [ HybridSearchStrategy::SearchResult.new(entity: widget, score: 0.9, matched_fields: [ "name" ]) ])
      )
      answers << "SynthWidget renders gadget frames. Sources: observation_id=#{first.id}"
    end

    def summarize = SummarizerService.call(query: "SynthWidget rendering")

    def ids
      { "observation_id=#{first.id}," => "observation_id=OBS1,", "observation_id=#{second.id}," => "observation_id=OBS2,",
        "entity_id=#{widget.id}," => "entity_id=ENT1," }
    end

    it "sends the golden prompt with no options beyond the defaults (Ollama)" do
      use_provider("ollama")

      response = summarize

      expect(placeholders(prompt_of(bodies.sole), ids)).to eq(golden("g1_summary_prompt"))
      expect(envelope_of(bodies.sole)).to eq("model" => "synth-model", "stream" => false,
                                             "options" => { "temperature" => 0.1, "num_predict" => 256, "num_ctx" => 8192 })
      expect(read_timeouts).to eq([ 30 ])
      expect(results.sole).to match(ok: true, text: answers_text(first), error: nil, latency_ms: kind_of(Float), prompt_tokens: 321, done_reason: "stop")
      expect(response).to include(generation_mode: "llm", generated_by: "synth-model", fallback_reason: nil)
    end

    it "sends the same prompt under openai_compatible" do
      use_provider("openai_compatible")

      summarize

      expect(placeholders(prompt_of(bodies.sole), ids)).to eq(golden("g1_summary_prompt"))
      expect(envelope_of(bodies.sole)).to eq("model" => "synth-model", "temperature" => 0.1, "max_tokens" => 256,
                                             "messages" => [ { "role" => "system", "content" => concise_system }, { "role" => "user", "content" => "PROMPT" } ])
      expect(results.sole).to match(ok: true, text: answers_text(first), error: nil, latency_ms: kind_of(Float), prompt_tokens: 321, done_reason: "stop")
    end

    it "shows a failed call's error as the fallback reason" do
      use_provider("ollama")
      allow(Net::HTTP).to receive(:new).and_raise(Errno::ECONNREFUSED)

      expect(summarize).to include(generation_mode: "deterministic", fallback_reason: "provider_unavailable")
      expect(results.sole).to match(ok: false, text: nil, error: "provider_unavailable", latency_ms: kind_of(Float), http_status: nil)
    end

    def answers_text(observation) = "SynthWidget renders gadget frames. Sources: observation_id=#{observation.id}"
  end

  describe "G3: a project scan in two parts (ProjectScanner → ChunkedExtraction)" do
    around do |example|
      Dir.mktmpdir("llm_characterization") do |dir|
        @root = File.realpath(dir)
        example.run
      end
    end

    before do
      FileUtils.mkdir_p(File.join(@root, "docs"))
      %w[alpha beta].each do |name|
        # About 4 KB in 8 long lines, so the two files don't fit one part of a 4096-token window.
        File.write(File.join(@root, "docs", "#{name}.md"), "# #{name}\n" + ("#{("The #{name} part of Gadget Project. " * 14).strip}\n" * 8))
      end
      AppSettings.summary_num_ctx = 4096
      AppSettings.project_scan_chunk_output_tokens = 512
      %w[alpha beta].each do |name|
        item = { entity: { name: "#{name.capitalize} Store", type: "Component" }, observations: [ "#{name.capitalize} Store is documented." ],
                 relations: [ { to: "Gadget Project", type: "part_of", confidence: 0.9 } ] }
        answers << { project: { name: "Gadget Project" }, architecture: [ item ] }.to_json
      end
    end

    def scan = ProjectScanner.new(project_root: @root, project_name: "Gadget Project", mode: "rescan").call

    it "sends the golden part prompts with num_ctx, num_predict, JSON, no truncation and the scan timeout (Ollama)" do
      use_provider("ollama")

      result = scan

      expect(bodies.map { |body| prompt_of(body) }).to eq([ golden("g3_scan_part1_prompt"), golden("g3_scan_part2_prompt") ])
      expect(bodies.map { |body| envelope_of(body) }).to all(eq("model" => "synth-model", "stream" => false, "format" => "json", "truncate" => false,
                                                                "options" => { "temperature" => 0.1, "num_predict" => 512, "num_ctx" => 4096 }))
      expect(read_timeouts).to eq([ 120, 120 ])
      # The keys ChunkedExtraction reads to decide a split (no client cut: max_output_length nil).
      expect(results).to all(match(ok: true, text: start_with('{"project"'), error: nil, latency_ms: kind_of(Float), prompt_tokens: 321, done_reason: "stop"))
      expect(result).to have_attributes(success: true, partial: false, parts_total: 2, parts_failed: 0)
    end

    it "sends the same prompts under openai_compatible (max_tokens, no format, num_ctx or truncate)" do
      use_provider("openai_compatible")

      scan

      expect(bodies.map { |body| prompt_of(body) }).to eq([ golden("g3_scan_part1_prompt"), golden("g3_scan_part2_prompt") ])
      expect(bodies.map { |body| envelope_of(body) }).to all(eq("model" => "synth-model", "temperature" => 0.1, "max_tokens" => 512,
                                                                "messages" => [ { "role" => "system", "content" => concise_system },
                                                                                { "role" => "user", "content" => "PROMPT" } ]))
      expect(read_timeouts).to eq([ 120, 120 ])
    end
  end

  describe "G4/G5: the fact-supersede judge (FactSupersedeJob and detect_contradictions)" do
    let!(:gadget) { fs_project!("Gadget Project") }
    let!(:widget) { fs_member!(gadget, "SynthWidget") }
    let!(:old) { fs_observe!(widget, "The MCP server runs on fast-mcp.", source: "manual") }
    let!(:fact) { fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]) }

    before { answers << [ { id: old.id, verdict: "superseded", confidence: 0.9, reason: "The fact names the mcp gem." } ].to_json }

    def ids = { %("id":#{old.id},) => %("id":"OBS1",) }

    def judge_body
      { "model" => "synth-model", "stream" => false, "format" => "json",
        "options" => { "temperature" => 0.1, "num_predict" => FactSupersede::Judge::NUM_PREDICT, "num_ctx" => 8192 } }
    end

    it "G4: sends the golden prompt for one batch (Ollama)" do
      use_provider("ollama")

      FactSupersedeJob.perform_now(fact.id)

      expect(placeholders(prompt_of(bodies.sole), ids)).to eq(golden("g4_judge_prompt"))
      expect(envelope_of(bodies.sole)).to eq(judge_body)
      expect(read_timeouts).to eq([ 30 ])
      expect(results.sole).to match(ok: true, text: start_with("[{"), error: nil, latency_ms: kind_of(Float), prompt_tokens: 321, done_reason: "stop")
    end

    it "G5: detect_contradictions sends the same prompt and body, inline in the MCP call" do
      use_provider("ollama")

      DetectContradictionsTool.new.call(entity_id: gadget.id, mode: "outdated_by_fact", fact_observation_id: fact.id)

      expect(placeholders(prompt_of(bodies.sole), ids)).to eq(golden("g4_judge_prompt"))
      expect(envelope_of(bodies.sole)).to eq(judge_body)
    end

    it "G4: sends the same prompt under openai_compatible" do
      use_provider("openai_compatible")

      FactSupersedeJob.perform_now(fact.id)

      expect(placeholders(prompt_of(bodies.sole), ids)).to eq(golden("g4_judge_prompt"))
      expect(envelope_of(bodies.sole)).to eq("model" => "synth-model", "temperature" => 0.1, "max_tokens" => FactSupersede::Judge::NUM_PREDICT,
                                             "messages" => [ { "role" => "system", "content" => concise_system }, { "role" => "user", "content" => "PROMPT" } ])
    end
  end
end
