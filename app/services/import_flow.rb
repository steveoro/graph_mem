# frozen_string_literal: true

require_relative "../../lib/import_session"

# The web import's upload (UI-6 P4) for Projects::ImportsController: a graph_mem-sql script goes to
# SqlImport::Flow (validate → dry run → preview; execute → report). The upload is never written to a path
# from the request (ImportSession names its files by a fresh UUID).
#
# JSON imports were retired in 1.94.0: a JSON file (a GraphMem export or a Graphify graph.json) is refused
# with that message. The JSON import engine stays for the rake imports (graphify:import, rails_ast:import).
#
#   upload = ImportFlow.upload(params[:file])
#   upload.error       # => nil, or the message to show on the upload form
#   upload.session_id  # => the ImportSession holding the script and its dry-run preview
class ImportFlow
  # The validator's own cap: a bigger file is refused before it's copied.
  MAX_UPLOAD_BYTES = SqlImport::Validator::MAX_BYTES

  Upload = Data.define(:session_id, :error)

  class << self
    # @param file [ActionDispatch::Http::UploadedFile, nil]
    # @return [Upload]
    def upload(file)
      return failed("Please select a file to import") if file.blank?
      return failed(too_large(file.size)) if file.size > MAX_UPLOAD_BYTES
      return failed(I18n.t("projects.imports.json_retired")) if json?(file)

      session_id = SqlImport::Flow.upload(file, file_name: File.basename(file.original_filename.to_s))
      Upload.new(session_id: session_id, error: nil)
    rescue SqlImport::Validator::Invalid => e
      failed(I18n.t("projects.imports.sql.invalid", reason: e.message))
    rescue SqlImport::Executor::Refused => e
      failed(I18n.t("projects.imports.sql.refused", reason: e.message))
    rescue ProjectMembership::LockTimeout
      failed(I18n.t("projects.imports.sql.busy"))
    rescue ActiveRecord::StatementInvalid => e
      failed(I18n.t("projects.imports.sql.refused", reason: SqlImport::Flow.refusal_reason(e)))
    rescue StandardError => e
      Rails.logger.error "Import upload failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      failed("Import failed: #{e.message}")
    end

    # @param file [#read, #rewind, #original_filename]
    # @return [Boolean] a JSON file: its name ends in .json, or its first non-blank character opens a JSON
    #   object or array (anything else goes to the validator, which refuses what isn't a graph_mem-sql script)
    def json?(file)
      head = file.read(64).to_s
      file.rewind
      File.extname(file.original_filename.to_s).casecmp?(".json") || head.lstrip.start_with?("{", "[")
    end

    private

    def failed(message)
      Upload.new(session_id: nil, error: message)
    end

    def too_large(size)
      "File too large (#{(size / 1.megabyte.to_f).round(1)} MB > #{MAX_UPLOAD_BYTES / 1.megabyte} MB)."
    end
  end
end
