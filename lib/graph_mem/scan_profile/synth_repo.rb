# frozen_string_literal: true

require "fileutils"
require "json"

module GraphMem
  module ScanProfile
    # The generated `synth` fixture of `graph_mem:scan_profile` (F-3b): a tiny "Gadget Project"
    # written into a temp dir, with an expected entity and relation list per profile, so recall,
    # precision and noise can be measured. It holds a README and a doc, a few Ruby classes
    # (SynthWidget, AlphaService, FrameBuffer) with known relations, one long file that must split
    # (ReportBuilder), one file over ProjectScanner::MAX_FILE_BYTES and one generated file.
    #
    # It also carries the canned answers of the stub backend (`.stub_answer`): the specs' fake
    # provider and script/scan_profile/fake_ollama.rb both answer from it, so a run without a
    # model is deterministic. The answers hold some deliberate noise (a generic name, an
    # extension-only name, an empty item, a duplicate observation, a self-relation, a short
    # observation, a generated class) for the metrics and the noise filter to find.
    #
    # Plain Ruby: script/scan_profile/fake_ollama.rb loads it without Rails.
    #
    #   SynthRepo.write(dir)                  # => dir, with the files below
    #   SynthRepo.expected("code")[:entities] # => ["SynthWidget", "AlphaService", "FrameBuffer", "ReportBuilder"]
    #   SynthRepo.stub_answer(prompt)         # => { text: "{…}", done_reason: "stop" }
    module SynthRepo
      KEY = "synth"
      PROJECT_NAME = "Gadget Project"
      # A part with this many file blocks or more is answered as cut ("length"), so the run
      # exercises a split; its halves are answered normally.
      SPLIT_AT = 3
      LONG_FILE = "lib/gadget/report_builder.rb"
      HUGE_FILE = "lib/gadget/huge_table.rb"
      PROFILES = {
        "docs" => %w[README* Gemfile docs/**/*.md],
        "code" => %w[lib/**/*.rb vendor/**/*.rb]
      }.freeze

      EXPECTED = {
        "docs" => { entities: %w[SynthWidget AlphaService FrameBuffer],
                    relations: [ %w[AlphaService depends_on SynthWidget], %w[SynthWidget uses FrameBuffer] ] },
        "code" => { entities: %w[SynthWidget AlphaService FrameBuffer ReportBuilder],
                    relations: [ %w[AlphaService depends_on SynthWidget], %w[SynthWidget uses FrameBuffer],
                                 %w[ReportBuilder uses FrameBuffer] ] }
      }.freeze

      PART_OF = { "to" => PROJECT_NAME, "type" => "part_of", "confidence" => 0.9 }.freeze

      # The stub backend's items per file. Noise, on purpose: Utils and Helper (generic, one
      # observation), ".md" (an extension), Gadget Notes (empty), a normalized duplicate, a
      # self-relation, "Fast." (short) and GeneratedSchema (a generated class, not expected).
      ANSWERS = {
        "README.md" => [
          { "entity" => { "name" => "SynthWidget", "type" => "Class" },
            "observations" => [ "SynthWidget renders gadget frames into a FrameBuffer." ],
            "relations" => [ PART_OF, { "to" => "FrameBuffer", "type" => "uses", "confidence" => 0.8 } ] },
          { "entity" => { "name" => "Utils", "type" => "Module" }, "observations" => [ "Utils holds shared helpers." ],
            "relations" => [] },
          { "entity" => { "name" => "Gadget Notes", "type" => "Concept" }, "observations" => [], "relations" => [] }
        ],
        "docs/architecture.md" => [
          { "entity" => { "name" => "AlphaService", "type" => "Service", "aliases" => [ "Alpha Service" ] },
            "observations" => [ "AlphaService schedules SynthWidget renders every second.",
                                "alphaservice schedules synthwidget renders every second" ],
            "relations" => [ PART_OF, { "to" => "SynthWidget", "type" => "depends_on", "confidence" => 0.9 } ] },
          { "entity" => { "name" => "FrameBuffer", "type" => "Class" },
            "observations" => [ "FrameBuffer keeps the last rendered gadget frames." ], "relations" => [ PART_OF ] },
          { "entity" => { "name" => ".md", "type" => "File" }, "observations" => [ "A Markdown document." ], "relations" => [] }
        ],
        "lib/gadget/synth_widget.rb" => [
          { "entity" => { "name" => "SynthWidget", "type" => "Class" },
            "observations" => [ "SynthWidget renders gadget frames into a FrameBuffer.", "SynthWidget#render returns the frame count." ],
            "relations" => [ PART_OF, { "to" => "FrameBuffer", "type" => "uses", "confidence" => 0.9 },
                             { "to" => "SynthWidget", "type" => "uses", "confidence" => 0.5 } ] }
        ],
        "lib/gadget/alpha_service.rb" => [
          { "entity" => { "name" => "AlphaService", "type" => "Service", "aliases" => [ "Alpha Service" ] },
            "observations" => [ "AlphaService schedules SynthWidget renders every second.", "Fast." ],
            "relations" => [ PART_OF, { "to" => "SynthWidget", "type" => "depends_on", "confidence" => 0.9 } ] }
        ],
        "lib/gadget/frame_buffer.rb" => [
          { "entity" => { "name" => "FrameBuffer", "type" => "Class" },
            "observations" => [ "FrameBuffer keeps the last rendered gadget frames.", "FrameBuffer drops frames beyond its capacity." ],
            "relations" => [ PART_OF ] },
          { "entity" => { "name" => "Helper", "type" => "Module" }, "observations" => [ "Helper module." ], "relations" => [] }
        ],
        LONG_FILE => [
          { "entity" => { "name" => "ReportBuilder", "type" => "Class" },
            "observations" => [ "ReportBuilder writes one report section per rendered frame." ],
            "relations" => [ PART_OF, { "to" => "FrameBuffer", "type" => "uses", "confidence" => 0.8 } ] }
        ],
        "vendor/gadget_generated.rb" => [
          { "entity" => { "name" => "GeneratedSchema", "type" => "Class" },
            "observations" => [ "GeneratedSchema lists the generated gadget columns." ], "relations" => [] }
        ]
      }.freeze

      module_function

      # Writes the repo's files into `dir`.
      #
      # @param dir [String] an empty temp dir
      # @return [String] dir
      def write(dir)
        files.each do |path, content|
          full = File.join(dir, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
        dir
      end

      # @param profile [String] "docs" or "code"
      # @return [Hash{Symbol => Array}] `{ entities: [names], relations: [[from, type, to]] }`
      def expected(profile)
        EXPECTED.fetch(profile)
      end

      # The stub backend's answer to one scan part: the canned items of each file block in the
      # prompt, or a cut answer for a part with SPLIT_AT blocks or more.
      #
      # @param prompt [String] a scan part's prompt
      # @return [Hash] `{ text:, done_reason: }`
      def stub_answer(prompt)
        paths = prompt.to_s.scan(/^--- FILE: (\S+)/).flatten
        return { text: '{"architecture": [', done_reason: "length" } if paths.size >= SPLIT_AT

        project = { "name" => PROJECT_NAME, "description" => ("Gadget Project renders gadget frames." if paths.include?("README.md")) }
        items = paths.uniq.flat_map { |path| ANSWERS.fetch(path, []) }
        { text: JSON.generate({ "project" => project.compact, "architecture" => items }), done_reason: "stop" }
      end

      # @return [Hash{String => String}] relative path => content
      def files
        {
          "README.md" => readme,
          "Gemfile" => %(source "https://rubygems.org"\n\ngem "rack"\n),
          "docs/architecture.md" => architecture,
          "lib/gadget/synth_widget.rb" => ruby_class("SynthWidget", "Renders gadget frames into a FrameBuffer.", "FrameBuffer.new.push(:frame)"),
          "lib/gadget/alpha_service.rb" => ruby_class("AlphaService", "Schedules SynthWidget renders every second.", "SynthWidget.new.render"),
          "lib/gadget/frame_buffer.rb" => ruby_class("FrameBuffer", "Keeps the last rendered gadget frames.", "@frames.last(8)"),
          LONG_FILE => long_file,
          HUGE_FILE => huge_file,
          "vendor/gadget_generated.rb" => "# This file is auto-generated by gadget-schema. Do not edit.\n" \
                                          "class GeneratedSchema\n  COLUMNS = %w[id name frames].freeze\nend\n"
        }
      end

      # The Manifest entry of the synthetic repo.
      #
      # @return [GraphMem::ScanProfile::Manifest::Repo]
      def manifest_repo
        Manifest::Repo.new(key: KEY, url: nil, commit: nil, license: nil, project_name: PROJECT_NAME, full: false,
                           exclude: [], profiles: PROFILES.transform_values(&:dup))
      end

      def readme
        <<~MD
          # Gadget Project

          Gadget Project renders gadget frames for the Alpha Service dashboard.

          - `SynthWidget` renders gadget frames into a `FrameBuffer`.
          - `AlphaService` schedules SynthWidget renders every second.
          - `ReportBuilder` writes one report section per rendered frame.
        MD
      end

      def architecture
        <<~MD
          # Architecture

          AlphaService depends on SynthWidget. SynthWidget uses FrameBuffer, which keeps the last
          rendered gadget frames. Files under `vendor/` are generated.
        MD
      end

      def ruby_class(name, summary, body)
        "# frozen_string_literal: true\n\n# #{summary}\nclass #{name}\n  def render\n    #{body}\n  end\nend\n"
      end

      # About 30 KB: more than one part at an 8192-token window, so the planner splits it.
      def long_file
        sections = (1..400).map { |i| "  # Section #{i} of the frame report.\n  def section_#{i}\n    \"Frame report section #{i}\"\n  end\n" }
        "# frozen_string_literal: true\n\n# Writes one report section per rendered frame.\nclass ReportBuilder\n#{sections.join("\n")}end\n"
      end

      # Over ProjectScanner::MAX_FILE_BYTES (50,000): never sent.
      def huge_file
        rows = (1..1_500).map { |i| "    [#{i}, \"gadget-frame-#{i}\", #{i * 7 % 101}]," }
        "# frozen_string_literal: true\n\nHUGE_TABLE = [\n#{rows.join("\n")}\n].freeze\n"
      end
      private_class_method :readme, :architecture, :ruby_class, :long_file, :huge_file
    end
  end
end
