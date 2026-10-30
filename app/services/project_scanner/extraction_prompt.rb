# frozen_string_literal: true

class ProjectScanner
  # The prompt of one scan part and the parsing of its answer (F-3; moved from ProjectScanner).
  # File contents and the earlier-parts names are untrusted data inside the prompt: nothing from
  # the answer is executed, used as a path or used to pick a file.
  #
  #   ProjectScanner::ExtractionPrompt.text(chunk.text, part: 2, parts: 3, project_name: "Gadget Project",
  #                                         names: ["SynthWidget"])
  #   ProjectScanner::ExtractionPrompt.parse_json("```json\n{\"architecture\": []}\n```") # => {"architecture"=>[]}
  module ExtractionPrompt
    # The names line never takes more than this, so the prompt's size is known before the names are.
    NAMES_RESERVE_BYTES = 1500

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
    # @return [String]
    def text(files_text, part:, parts:, project_name:, names: [])
      <<~PROMPT
        #{INSTRUCTIONS}
        This is part #{part} of #{parts} of one project (project name: #{project_name}). Other parts hold other files; describe only the files in this part.
        #{names_line(names)}
        Files:
        #{files_text}
      PROMPT
    end

    # @param project_name [String]
    # @param bytes_per_token [Numeric] the estimate (TokenEstimate)
    # @return [Integer] the estimated tokens of a part's prompt without files, the names reserve included
    def overhead_tokens(project_name, bytes_per_token: TokenEstimate::BYTES_PER_TOKEN)
      bytes = text("", part: 999, parts: 999, project_name: project_name).bytesize + NAMES_RESERVE_BYTES
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

    def names_line(names)
      return "" if names.blank?

      line = +"Entities already found (reuse these exact names when you mean the same thing): "
      kept = names.map { |name| name.to_s.squish }.reject(&:blank?).take_while do |name|
        (line.bytesize + name.bytesize + 2) <= NAMES_RESERVE_BYTES && line << name << "; "
      end
      kept.any? ? "#{line.delete_suffix('; ')}\n" : ""
    end
    private_class_method :names_line
  end
end
