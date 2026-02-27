require "yaml"
require "rails"

DUMP_FILENAME = "graph_mem.sql.bz2"

namespace :db do
  desc "Dump the current database to db/backup/#{DUMP_FILENAME}"
  task dump: :environment do
    db_name, cmd_params = extract_cmd_params
    backup_dir = Rails.root.join("db", "backup")
    backup_file = backup_dir.join(DUMP_FILENAME)

    FileUtils.mkdir_p(backup_dir)

    puts "Dumping database '#{db_name}' to '#{backup_file}'..."

    mysqldump_cmd = "mariadb-dump" + cmd_params
    mysqldump_cmd += " --no-tablespaces"
    mysqldump_cmd += " --no-create-db"
    mysqldump_cmd += " #{db_name}"

    full_cmd = "#{mysqldump_cmd} | bzip2 > #{backup_file}"

    success = system(full_cmd)

    if success
      puts "Database dump completed successfully."
    else
      puts "Database dump failed."
    end
  end
  # ---------------------------------------------------------------------------

  desc "Restore the current database from db/backup/#{DUMP_FILENAME} (Drops existing DB!)"
  task restore: :environment do
    db_name, cmd_params = extract_cmd_params
    backup_dir = Rails.root.join("db", "backup")
    backup_file = backup_dir.join(DUMP_FILENAME)

    unless File.exist?(backup_file)
      puts "Backup file not found: #{backup_file}"
      exit 1
    end

    puts "Restoring database '#{db_name}' from '#{backup_file}'..."
    puts "*** THIS WILL DROP THE EXISTING DATABASE '#{db_name}' ***"

    mysql_base_cmd = "mariadb" + cmd_params

    drop_cmd = "#{mysql_base_cmd} -e 'DROP DATABASE IF EXISTS \`#{db_name}\`;'"
    create_cmd = "#{mysql_base_cmd} -e 'CREATE DATABASE \`#{db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
    restore_cmd = "bzcat #{backup_file} | #{mysql_base_cmd} #{db_name}"

    puts "Dropping database..."
    unless system(drop_cmd)
      puts "Failed to drop database."
      exit 1
    end

    puts "Creating database..."
    unless system(create_cmd)
      puts "Failed to create database."
      exit 1
    end

    puts "Restoring data..."
    unless system(restore_cmd)
      puts "Failed to restore database."
      exit 1
    end

    puts "Database restore completed successfully."
  end
  # ---------------------------------------------------------------------------

  def extract_cmd_params
    if ENV["DATABASE_URL"].present?
      uri = URI.parse(ENV["DATABASE_URL"])
      db_name  = uri.path.sub(%r{^/}, "")
      db_user  = uri.user
      db_pass  = uri.password
      db_host  = uri.host
      db_port  = uri.port
    else
      db_config = resolve_db_config
      db_name   = db_config["database"]
      db_user   = db_config["username"]
      db_pass   = db_config["password"]
      db_host   = db_config["host"]
      db_port   = db_config["port"]
      db_socket = db_config["socket"]
    end

    abort "ERROR: Could not determine database name." if db_name.blank?

    result = " -u #{db_user}"
    result += " -p'#{db_pass}'" if db_pass.present?
    result += " -h #{db_host}" if db_host.present? && db_host != "localhost"
    result += " -P #{db_port}" if db_port.present? && db_port.to_i != 3306
    result += " -S #{db_socket}" if db_socket.present?
    [ db_name, result ]
  end

  def resolve_db_config
    config = Rails.configuration.database_configuration[Rails.env]
    config.is_a?(Hash) && config.key?("primary") ? config["primary"] : config
  end
  # ---------------------------------------------------------------------------
end
