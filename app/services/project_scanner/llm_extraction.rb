# frozen_string_literal: true

class ProjectScanner
  # ProjectScanner's LLM extraction (F-3): ChunkPlanner's parts, ChunkedExtraction's requests and
  # ExtractionMerger's result, with the counters kept in details["extraction"]. Private methods of
  # ProjectScanner; they read and set its instance variables.
  module LlmExtraction
    private

    # The LLM path: the planner's parts, one request each, merged (F-3). Without the LLM, or when
    # summary_num_ctx leaves no room for files, the files are read as one text for the validator and
    # the deterministic fallback runs, as before.
    # @return [Hash] `{ data:, fallback:, fallback_reason: }`
    def extract_knowledge
      return fallback_extraction("LLM summarization disabled or unavailable", "LLM summarization unavailable") if summarization_disabled_or_unavailable?

      plan = plan_parts
      if plan.error == :window_too_small
        return fallback_extraction("summary_num_ctx (#{scan_num_ctx}) leaves no room for project files; raise it to at least 4096",
                                   "The context window leaves no room for project files")
      end

      @context_text = plan.context_text
      record_extraction(plan: plan)
      outcome = ChunkedExtraction.new(
        chunks: plan.chunks, project_name: prompt_project_name, num_ctx: scan_num_ctx,
        num_predict: scan_num_predict, timeout: [ SummarizationConfig.resolved_config[:timeout].to_i, 120 ].max,
        on_part: ->(part, parts) { part_progress!(part, parts) }
      ).call
      record_extraction(plan: plan, outcome: outcome)
      if partial?
        @extraction["partial"] = true
        save_extraction_details!
      end
      return { data: outcome.data } if outcome.data

      reason = outcome.first_error
      fallback_extraction(reason, reason == "LLM response was not valid JSON" ? "LLM response was not valid JSON" : "LLM extraction failed")
    end

    def fallback_extraction(reason, message)
      whole = whole_plan
      @context_text = whole.context_text
      record_extraction(plan: whole, fallback: true)
      update_progress!(phase: "fallback_extraction", message: "#{message}; using deterministic fallback")
      { data: deterministic_extraction, fallback: true, fallback_reason: reason }
    end

    # Every file the caps allow, as one part: the validator's text when no part goes to the model.
    def whole_plan
      ChunkPlanner.new(files: @discovered_files, root: @file_filter.root, input_budget: @max_total_input_bytes,
                       max_chunks: 1, max_total_bytes: @max_total_input_bytes).call
    end

    def plan_parts
      bytes_per_token = AppSettings.project_scan_bytes_per_token.to_f.clamp(2.0, 6.0)
      budget = TokenEstimate.input_budget(num_ctx: scan_num_ctx, num_predict: scan_num_predict,
                                          prompt_tokens: ExtractionPrompt.overhead_tokens(prompt_project_name, bytes_per_token: bytes_per_token))
      ChunkPlanner.new(files: @discovered_files, root: @file_filter.root, input_budget: budget, bytes_per_token: bytes_per_token,
                       max_chunks: AppSettings.project_scan_max_chunks.to_i.clamp(1, 64), max_total_bytes: @max_total_input_bytes).call
    end

    def prompt_project_name
      @project_name || File.basename(@project_root)
    end

    def scan_num_ctx
      SummarizationConfig.resolved_config[:num_ctx].to_i
    end

    def scan_num_predict
      AppSettings.project_scan_chunk_output_tokens.to_i.clamp(512, 8192)
    end

    # details["extraction"] on the scan: the parts and files, kept current while the parts run.
    def record_extraction(plan:, outcome: nil, fallback: false)
      @extraction = {
        "parts_total" => outcome&.parts_total || (fallback ? 0 : plan.chunks.size), "parts_done" => outcome&.parts_done || 0,
        "parts_failed" => outcome&.parts_failed || 0, "files_read" => plan.files_read, "files_too_large" => plan.files_too_large,
        "files_over_budget" => plan.files_over_budget, "left_out" => plan.left_out, "input_budget_tokens" => (plan.input_budget unless fallback),
        "num_ctx" => scan_num_ctx, "num_predict" => (scan_num_predict unless fallback), "reconciled" => false
      }.compact
      save_extraction_details!
    end

    # A scan is complete when every part succeeded and every discovered file was sent. The
    # deterministic fallback is never partial (it keeps its old behaviour).
    def partial?
      return false if @extraction.empty? || @extraction["input_budget_tokens"].nil?

      @extraction.values_at("parts_failed", "files_too_large", "files_over_budget").any? { |count| count.to_i.positive? }
    end

    def partial_message
      left_out = @extraction["files_too_large"].to_i + @extraction["files_over_budget"].to_i
      parts = "#{@extraction['parts_failed'].to_i} of #{@extraction['parts_total'].to_i} parts failed"
      "Partial: #{parts}#{", #{left_out} files left out" if left_out.positive?}; nothing was marked missing"
    end

    def part_progress!(part, parts)
      @extraction_base ||= @operation_progress&.current_count.to_i
      @extraction["parts_total"] = parts
      @extraction["parts_done"] = part - 1
      save_extraction_details!
      update_progress!(phase: "extracting_knowledge", message: "Extracting knowledge: part #{part} of #{parts}",
                       current: @extraction_base.to_i + part, total: @extraction_base.to_i + parts + 3)
    end

    def save_extraction_details!
      return unless @operation_progress

      @operation_progress.update!(details: (@operation_progress.details || {}).merge("extraction" => @extraction))
    end

    def summarization_disabled_or_unavailable?
      !SummarizationConfig.llm_usable?
    end

    # Saved after reconcile so a resumed paused scan (C6) skips the model and reconcile: the
    # project, the merged names for the validator and the extraction's outcome.
    def record_reconciled!(extracted)
      return if @dry_run || @project_entity.nil?

      names = Array(@extracted_data["architecture"]).filter_map { |item| item.dig("entity", "name").to_s.strip.presence if item.is_a?(Hash) }
      @extraction.merge!("reconciled" => true, "project_root" => @project_root, "project_entity_id" => @project_entity.id,
                         "names" => names.uniq.first(500), "fallback" => extracted[:fallback] == true,
                         "fallback_reason" => extracted[:fallback_reason]).compact!
      save_extraction_details!
    end

    # @return [Hash, nil] the saved extraction of this scan when it was reconciled for this root
    def reconciled_extraction
      saved = @operation_progress&.details&.dig("extraction")
      saved if saved.is_a?(Hash) && saved["reconciled"] == true && saved["project_root"] == @project_root
    end

    # A claimed paused scan whose extraction was reconciled: no model call and no second
    # reconcile. The files are read again only for the validator's text.
    def resume_validation
      @extraction = reconciled_extraction
      @project_entity = MemoryEntity.find_by(id: @extraction["project_entity_id"])
      return failed_result("Project entity ##{@extraction['project_entity_id']} of the paused scan no longer exists") unless @project_entity

      update_progress!(phase: "reading_files", message: "Resuming: reading the files again for validation (no model call)")
      @discovered_files = discover_files
      @context_text = whole_plan.context_text
      @extracted_data = { "architecture" => Array(@extraction["names"]).map { |name| { "entity" => { "name" => name } } } }
      validate_and_finish({ fallback: @extraction["fallback"] == true, fallback_reason: @extraction["fallback_reason"] })
    end
  end
end
