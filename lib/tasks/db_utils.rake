require "yaml"
require "rails"

namespace :db do
  desc "Dump the development database to db/backup/graph_mem.sql.bz2"
  task dump: :environment do
    config_path = Rails.root.join("config", "database.yml")
    config = YAML.load_file(config_path)["development"]

    db_name = config["database"]
    db_user = config["username"]
    db_pass = config["password"]
    db_host = config["host"] || "localhost" # Default to localhost if not specified
    db_socket = config["socket"]

    backup_dir = Rails.root.join("db", "backup")
    backup_file = backup_dir.join("#{db_name}.sql.bz2")

    # Ensure backup directory exists (it should, we created it earlier)
    FileUtils.mkdir_p(backup_dir)

    puts "Dumping database '#{db_name}' to '#{backup_file}'..."

    # Build the command parts, handling potential nil password
    mysqldump_cmd = "mysqldump"
    mysqldump_cmd += " -u#{db_user}"
    mysqldump_cmd += " -p'#{db_pass}'" if db_pass.present? # Use quotes for safety
    mysqldump_cmd += " -h#{db_host}" if db_host != "localhost"
    mysqldump_cmd += " -S#{db_socket}" if db_socket.present?
    mysqldump_cmd += " --no-tablespaces" # Often needed for RDS compatibility/simpler dumps
    mysqldump_cmd += " #{db_name}"

    # Pipe through bzip2
    full_cmd = "#{mysqldump_cmd} | bzip2 > #{backup_file}"

    success = system(full_cmd)

    if success
      puts "Database dump completed successfully."
    else
      puts "Database dump failed."
      # Consider raising an error: raise 'Database dump failed!'
    end
  end

  desc "Restore the development database from db/backup/graph_mem.sql.bz2 (Drops existing DB!)"
  task restore: :environment do
    config_path = Rails.root.join("config", "database.yml")
    config = YAML.load_file(config_path)["development"]

    db_name = config["database"]
    db_user = config["username"]
    db_pass = config["password"]
    db_host = config["host"] || "localhost"
    db_socket = config["socket"]

    backup_dir = Rails.root.join("db", "backup")
    backup_file = backup_dir.join("#{db_name}.sql.bz2")

    unless File.exist?(backup_file)
      puts "Backup file not found: #{backup_file}"
      exit 1
    end

    puts "Restoring database '#{db_name}' from '#{backup_file}'..."
    puts "*** THIS WILL DROP THE EXISTING DATABASE '#{db_name}' ***"

    # Build base mysql command parts
    mysql_base_cmd = "mysql"
    mysql_base_cmd += " -u#{db_user}"
    mysql_base_cmd += " -p'#{db_pass}'" if db_pass.present?
    mysql_base_cmd += " -h#{db_host}" if db_host != "localhost"
    mysql_base_cmd += " -S#{db_socket}" if db_socket.present?

    # Commands to drop and create
    drop_cmd = "#{mysql_base_cmd} -e 'DROP DATABASE IF EXISTS \`#{db_name}\`;'"
    create_cmd = "#{mysql_base_cmd} -e 'CREATE DATABASE \`#{db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
    # Restore command (pipe bzcat output)
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
end
