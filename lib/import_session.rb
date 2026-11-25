# frozen_string_literal: true

# Helper class to manage temporary file storage for import sessions
# This replaces session-based storage to avoid cookie overflow issues.
# A JSON upload keeps its parsed data, matches and stats; a graph_mem-sql upload keeps the script
# itself (`<id>_script.sql`) and its dry-run preview (create_sql).
class ImportSession
  TEMP_DIR = Rails.root.join("tmp", "data_exchange")

  class << self
    # Create a new import session with the given data
    # @param import_data [Hash] The parsed JSON import data
    # @param matches [Array] The serialized match results
    # @param stats [Hash] Import statistics
    # @param version [String] Import format version
    # @param meta [Hash] what the upload was (file_name, producer, project_name), for the history
    # @return [String] The session ID
    def create(import_data:, matches:, stats:, version:, meta: {})
      session_id = SecureRandom.uuid
      ensure_temp_dir

      write_file(session_id, "data", import_data)
      write_file(session_id, "matches", matches)
      write_file(session_id, "stats", stats)
      write_file(session_id, "version", { version: version })
      write_file(session_id, "meta", meta)

      session_id
    end

    # Check if an import session exists
    # @param session_id [String] The session ID
    # @return [Boolean]
    def exists?(session_id)
      return false if session_id.blank?

      File.exist?(path_for(session_id, "data")) || sql?(session_id)
    end

    # Stores an uploaded graph_mem-sql script under a fresh id (copied as it is, never parsed here)
    # @param io [#read] the upload
    # @param meta [Hash] what the upload was (file_name, producer)
    # @return [String] the session ID
    def create_sql(io, meta:)
      session_id = SecureRandom.uuid
      ensure_temp_dir
      File.open(sql_path(session_id), "wb") { |file| IO.copy_stream(io, file) }
      write_file(session_id, "meta", meta)
      session_id
    end

    # @param session_id [String] The session ID
    # @return [String] where the session's script is (it may not exist)
    def sql_path(session_id)
      File.join(TEMP_DIR, "#{session_id}_script.sql")
    end

    # @param session_id [String] The session ID
    # @return [Boolean] the session holds a graph_mem-sql script
    def sql?(session_id)
      session_id.present? && File.exist?(sql_path(session_id))
    end

    # Store a graph_mem-sql script's dry-run preview
    # @param session_id [String] The session ID
    # @param preview [Hash]
    def store_preview(session_id, preview)
      write_file(session_id, "preview", preview)
    end

    # Load a graph_mem-sql script's dry-run preview, with string keys (as operation details have)
    # @param session_id [String] The session ID
    # @return [Hash, nil]
    def load_preview(session_id)
      path = path_for(session_id, "preview")
      File.exist?(path) ? JSON.parse(File.read(path)) : nil
    end

    # Load import data from a session
    # @param session_id [String] The session ID
    # @return [Hash, nil] The import data or nil if not found
    def load_data(session_id)
      read_file(session_id, "data")
    end

    # Load match results from a session
    # @param session_id [String] The session ID
    # @return [Array, nil] The match results or nil if not found
    def load_matches(session_id)
      read_file(session_id, "matches")
    end

    # Load stats from a session
    # @param session_id [String] The session ID
    # @return [Hash, nil] The stats or nil if not found
    def load_stats(session_id)
      read_file(session_id, "stats")
    end

    # Load version from a session
    # @param session_id [String] The session ID
    # @return [String, nil] The version or nil if not found
    def load_version(session_id)
      data = read_file(session_id, "version")
      data&.dig(:version) || data&.dig("version")
    end

    # Load what the upload was (file_name, producer, project_name)
    # @param session_id [String] The session ID
    # @return [Hash] empty for a session written before the meta file existed
    def load_meta(session_id)
      read_file(session_id, "meta") || {}
    end

    # Store the import report
    # @param session_id [String] The session ID
    # @param report [Hash] The import report
    def store_report(session_id, report)
      ensure_temp_dir
      write_file(session_id, "report", report)
    end

    # Load the import report
    # @param session_id [String] The session ID
    # @return [Hash, nil] The report or nil if not found
    def load_report(session_id)
      read_file(session_id, "report")
    end

    # Check if a report exists for a session
    # @param session_id [String] The session ID
    # @return [Boolean]
    def report_exists?(session_id)
      return false if session_id.blank?

      File.exist?(path_for(session_id, "report"))
    end

    # Clean up all files for a session
    # @param session_id [String] The session ID
    def cleanup(session_id)
      return if session_id.blank?

      %w[data matches stats version meta report preview].each do |suffix|
        FileUtils.rm_f(path_for(session_id, suffix))
      end
      FileUtils.rm_f(sql_path(session_id))
    end

    # Clean up old sessions (older than specified age)
    # @param max_age [Integer] Maximum age in seconds (default: 24 hours)
    def cleanup_old_sessions(max_age: 24.hours.to_i)
      return unless Dir.exist?(TEMP_DIR)

      cutoff_time = Time.current - max_age

      Dir.glob(File.join(TEMP_DIR, "*.{json,sql}")).each do |file|
        if File.mtime(file) < cutoff_time
          FileUtils.rm_f(file)
        end
      end
    end

    private

    def ensure_temp_dir
      FileUtils.mkdir_p(TEMP_DIR)
    end

    def path_for(session_id, suffix)
      File.join(TEMP_DIR, "#{session_id}_#{suffix}.json")
    end

    def write_file(session_id, suffix, data)
      File.write(path_for(session_id, suffix), data.to_json)
    end

    def read_file(session_id, suffix)
      path = path_for(session_id, suffix)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path), symbolize_names: true)
    rescue JSON::ParserError => e
      Rails.logger.error "ImportSession: Failed to parse #{suffix} file: #{e.message}"
      nil
    end
  end
end
