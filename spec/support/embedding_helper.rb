# frozen_string_literal: true

RSpec.configure do |config|
  config.before(:suite) do
    conn = ActiveRecord::Base.connection

    %w[memory_entities memory_observations].each do |table|
      idx = "idx_#{table}_embedding"
      result = conn.execute("SHOW INDEX FROM #{table} WHERE Key_name = '#{idx}'")
      if result.count > 0
        conn.execute("ALTER TABLE #{table} DROP INDEX #{idx}")
      end
      conn.execute("ALTER TABLE #{table} MODIFY embedding VECTOR(768) DEFAULT NULL")
    end
  end

  config.before(:each) do
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)
  end

  config.after(:suite) do
    EmbeddingService.reset_vector_cache!
  end
end
