# frozen_string_literal: true

class ProjectScanner
  # The prompt of one scan part and the parsing of its answer (F-3; moved from ProjectScanner).
  # File contents, the project name and the earlier-parts names are untrusted data inside the
  # prompt (`data` segments of an Llm::Prompt): nothing from the answer is executed, used as a
  # path or used to pick a file.
  #
  #   ProjectScanner::ExtractionPrompt.text(chunk.text, part: 2, parts: 3, project_name: "Gadget Project",
  #                                         names: ["SynthWidget"])
  #   ProjectScanner::ExtractionPrompt.parse_json("```json\n{\"architecture\": []}\n```") # => {"architecture"=>[]}
  module ExtractionPrompt
    # The names line never takes more than this, so the prompt's size is known before the names are.
    NAMES_RESERVE_BYTES = 1500
    NAMES_PREFIX = "Entities already found (reuse these exact names when you mean the same thing): "
    # The code-map section (1.75.0, Rails projects only) never takes more than this.
    CODE_MAP_RESERVE_BYTES = 2000
    CODE_MAP_OWN = "Code entities defined in these files (use exactly these names and types for them, never a shorter name): "
    CODE_MAP_RELATED = "Other code entities of this project (use these exact names when you mean them): "
    CODE_MAP_GEMS = "A gem declared in the Gemfile or a gemspec is type Gem.\n"

    INSTRUCTIONS = <<~PROMPT
      You are a codebase knowledge extractor. Analyze the project files below and produce a single JSON object.

      Required JSON structure:
      {
        "project": {
          "name": "short project name",
          "aliases": ["optional alias 1", "optional alias 2"],
          "description": "one sentence description"
        },
        "architecture": [
          {
            "entity": {
              "name": "entity name",
              "type": "one of: Project, Component, Service, Class, Module, Configuration, Framework, DatabaseTable, APIEndpoint, Route, Migration, TestCase, BestPractice, Preference, Issue, PossibleSolution, Workflow, ApplicationStack, Model, User, Step, Task, Error",
              "aliases": ["..."],
              "description": "..."
            },
            "observations": ["factual statement 1", "factual statement 2"],
            "relations": [
              { "to": "target entity name or project name", "type": "part_of or depends_on or relates_to or implements or extends or configured_by or tested_by", "confidence": 0.9 }
            ]
          }
        ]
      }

      Rules:
      - Only include facts that are directly supported by the file contents.
      - Do not invent files, directories, or entities not mentioned.
      - Use the project root as the top-level parent for "part_of" relations.
      - Keep the response valid JSON only, no markdown.
    PROMPT

    module_function

    # @param files_text [String] the part's files ("--- FILE: …" blocks)
    # @param part [Integer] 1-based
    # @param parts [Integer]
    # @param project_name [String]
    # @param names [Array<String>] entity names from earlier parts (cut to NAMES_RESERVE_BYTES)
    # @param guide [Hash, nil] the code-map section (ProjectScanner::CodeMapGuide#prompt_guide):
    #   `{ own: ["GogglesDb::Badge (Model)", …], related: [...], gems: true }`, cut to
    #   CODE_MAP_RESERVE_BYTES; nil (not a Rails project) adds nothing
    # @return [String]
    def text(files_text, part:, parts:, project_name:, names: [], guide: nil)
      build(files_text, part: part, parts: parts, project_name: project_name, names: names, guide: guide).to_s
    end

    # @param (see .text)
    # @return [Llm::Prompt] the same prompt as segments, for the Router (a cloud provider masks the data)
    def build(files_text, part:, parts:, project_name:, names: [], guide: nil)
      prompt = Llm::Prompt.new.trusted("#{INSTRUCTIONS}\nThis is part #{part} of #{parts} of one project (project name: ")
                          .data(project_name)
                          .trusted("). Other parts hold other files; describe only the files in this part.\n")
      kept = kept_names(names)
      prompt.trusted(NAMES_PREFIX).data(kept.join("; ")).trusted("\n") if kept.any?
      add_code_map(prompt, guide) if guide
      prompt.trusted("\nFiles:\n").data(files_text).trusted("\n")
    end

    # @param project_name [String]
    # @param bytes_per_token [Numeric] the estimate (TokenEstimate)
    # @param code_map [Boolean] a Rails code map exists: CODE_MAP_RESERVE_BYTES are counted too
    # @return [Integer] the estimated tokens of a part's prompt without files, the names reserve included
    def overhead_tokens(project_name, bytes_per_token: TokenEstimate::BYTES_PER_TOKEN, code_map: false)
      bytes = text("", part: 999, parts: 999, project_name: project_name).bytesize + NAMES_RESERVE_BYTES
      bytes += CODE_MAP_RESERVE_BYTES if code_map
      TokenEstimate.tokens("x" * bytes, bytes_per_token: bytes_per_token)
    end

    # @param text [String, nil] the model's answer, optionally in a ```json fence
    # @return [Object, nil] the parsed JSON, nil when it isn't JSON
    def parse_json(text)
      return nil if text.blank?

      text = text.strip
      text = text.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\s*\z/m, "") if text.start_with?("```")
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    # The names that fit the names line ("prefix name1; name2", within NAMES_RESERVE_BYTES with
    # room for a "; " after each).
    def kept_names(names)
      bytes = NAMES_PREFIX.bytesize
      Array(names).map { |name| name.to_s.squish }.reject(&:blank?).take_while do |name|
        (bytes + name.bytesize + 2) <= NAMES_RESERVE_BYTES && (bytes += name.bytesize + 2)
      end
    end

    # The code-map lines, each list cut so the section stays within CODE_MAP_RESERVE_BYTES. The
    # names are data segments (a cloud provider's anonymizer masks them like file contents).
    def add_code_map(prompt, guide)
      left = CODE_MAP_RESERVE_BYTES
      { CODE_MAP_OWN => guide[:own], CODE_MAP_RELATED => guide[:related] }.each do |prefix, labels|
        kept = fitting(labels, left - prefix.bytesize - 1)
        next if kept.empty?

        prompt.trusted(prefix).data(kept.join("; ")).trusted("\n")
        left -= prefix.bytesize + kept.join("; ").bytesize + 1
      end
      prompt.trusted(CODE_MAP_GEMS) if guide[:gems] && CODE_MAP_GEMS.bytesize <= left
    end

    def fitting(labels, room)
      bytes = 0
      Array(labels).map { |label| label.to_s.squish }.reject(&:blank?).take_while do |label|
        (bytes + label.bytesize + 2) <= room && (bytes += label.bytesize + 2)
      end
    end
    private_class_method :kept_names, :add_code_map, :fitting
  end
end
