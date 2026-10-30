# frozen_string_literal: true

require_relative "../../lib/import_session"

# The web import (UI-6 P4): upload → review → execute, for a GraphMem export or a Graphify
# graph.json (Projects::ImportsController), on top of the existing services:
# ImportMatchingStrategy, ImportExecutionStrategy, ImportSession and GraphifyImporter. The upload is parsed in memory, under MAX_UPLOAD_BYTES,
# and never written to a path from the request (ImportSession names its files by a fresh UUID).
#
#   upload = ImportFlow.upload(params[:file], project_name: "Alpha Service")
#   upload.error              # => nil, or the message to show on the upload form
#   operation = ImportFlow.execute(upload.session_id, params[:decisions])
#   operation.details["summary"] # => { "entities_created" => 3, "entities_merged" => 1, … }
class ImportFlow
  # 64 MB covers ~50k-node graphs with headroom; bigger files go through the rake imports.
  MAX_UPLOAD_BYTES = 64.megabytes
  MAX_STORED_ERRORS = 20
  SUMMARY_KEYS = %i[entities_created entities_merged entities_skipped observations_created relations_created].freeze

  # needs_project_name: a Graphify graph.json arrived without a project name; suggested_name is
  # the file's base name, to pre-fill the field.
  Upload = Data.define(:session_id, :error, :needs_project_name, :suggested_name)

  class << self
    # @param file [ActionDispatch::Http::UploadedFile, nil]
    # @param project_name [String, nil] the Project a Graphify graph.json describes
    # @return [Upload]
    def upload(file, project_name: nil)
      return failed("Please select a file to import") if file.blank?
      return failed(too_large(file.size)) if file.size > MAX_UPLOAD_BYTES

      data = JSON.parse(file.read)
      file_name = File.basename(file.original_filename.to_s)
      producer = graphify?(data) ? "graphify" : "graph_mem"
      if producer == "graphify"
        name = project_name.to_s.strip.presence
        return Upload.new(session_id: nil, error: "Name the project this Graphify graph.json describes.", needs_project_name: true,
                          suggested_name: File.basename(file_name, ".*")) unless name

        data = translate_graphify(data, name)
      end
      store(data, file_name: file_name, producer: producer, project_name: name)
    rescue ImportObservationDuplicateDetector::UnavailableError => e
      Rails.logger.error "Import upload requires embeddings: #{e.message}"
      failed("Import requires the embedding service for observation de-duplication: #{e.message}")
    rescue JSON::ParserError => e
      failed("Invalid JSON file: #{e.message}")
    rescue ArgumentError => e
      failed("Invalid Graphify graph.json: #{e.message}")
    rescue StandardError => e
      Rails.logger.error "Import upload failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      failed("Import failed: #{e.message}")
    end

    # Runs the reviewed import inside the request (Decision 3) and records it in the history:
    # the OperationProgress's details hold the file, producer, project and the report summary.
    # The import session's files are removed afterwards.
    #
    # @param session_id [String] an existing ImportSession id
    # @param root_decisions [ActionController::Parameters, Hash, nil] the review form's decisions
    # @return [OperationProgress]
    def execute(session_id, root_decisions)
      import_data = ImportSession.load_data(session_id)
      decisions = ImportDecisions.merge(root_decisions, ImportSession.load_matches(session_id))
      meta = ImportSession.load_meta(session_id).stringify_keys
      operation = OperationProgress.start!(operation_type: "import", total_count: 0, message: "Starting import", details: meta)
      tracker = OperationProgressTracker.new(operation_progress: operation, total: 0, message: "Starting import")
      report = ImportExecutionStrategy.new(progress_tracker: tracker).execute(import_data, decisions)

      project_id = ImportDecisions.project_entity_id(import_data, decisions)
      seed_ambiguous(import_data, project_id) if report.success
      record(operation, meta, report, project_id, import_data)
      ImportSession.cleanup(session_id)
      operation
    end

    # @return [Boolean] a Graphify graph.json: top-level nodes plus links or edges, no root_nodes
    def graphify?(data)
      data.is_a?(Hash) && !data.key?("root_nodes") && data["nodes"].is_a?(Array) &&
        (data["links"].is_a?(Array) || data["edges"].is_a?(Array))
    end

    private

    def failed(message)
      Upload.new(session_id: nil, error: message, needs_project_name: false, suggested_name: nil)
    end

    def too_large(size)
      "File too large (#{(size / 1.megabyte.to_f).round(1)} MB > #{MAX_UPLOAD_BYTES / 1.megabyte} MB). " \
        "Use `rails graphify:import` or `rails_ast:import` instead."
    end

    # The same payload `rake graphify:translate` writes: the import data plus the withheld edges.
    def translate_graphify(data, project_name)
      result = GraphifyImporter.new(data, project_name: project_name).translate
      result.import_data.merge("ambiguous_relations" => result.ambiguous_relations)
    end

    def store(data, file_name:, producer:, project_name:)
      match = ImportMatchingStrategy.new.match(data)
      return failed(match[:error]) unless match[:success]

      session_id = ImportSession.create(
        import_data: data, matches: match[:match_results].map(&:to_h), stats: match[:stats], version: match[:version],
        meta: { file_name: file_name, producer: producer, project_name: project_name || ImportDecisions.root_name(data) }
      )
      Upload.new(session_id: session_id, error: nil, needs_project_name: false, suggested_name: nil)
    end

    # Graphify payloads carry withheld AMBIGUOUS edges; queue them for review only after the import
    # succeeded, so their endpoints resolve to real entities.
    def seed_ambiguous(import_data, project_id)
      return if import_data[:ambiguous_relations].blank?

      producer = import_data[:producer].to_s
      GraphifyImporter.seed_ambiguous_relations(
        import_data[:ambiguous_relations].map(&:deep_stringify_keys),
        ImportDecisions.root_name(import_data) || "import",
        source: GraphifyImporter::KNOWN_PRODUCERS.include?(producer) ? producer : "graphify",
        project_id: project_id
      )
    end

    def record(operation, meta, report, project_id, import_data)
      summary = report.to_h.slice(*SUMMARY_KEYS).transform_keys(&:to_s).merge("errors" => report.errors.size)
      operation.reload.update!(details: (operation.details || {}).merge(meta).merge(
        "project_name" => meta["project_name"].presence || ImportDecisions.root_name(import_data),
        "project_entity_id" => project_id, "success" => report.success, "summary" => summary,
        "error_messages" => report.errors.first(MAX_STORED_ERRORS).map { |error| error.to_s.truncate(500) }
      ).compact)
    end
  end
end
