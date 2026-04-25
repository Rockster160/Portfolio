class BackfillExecutionPayloads < ActiveRecord::Migration[7.1]
  def up
    say_with_time "Backfilling execution_payloads from legacy execution columns" do
      execute(<<~SQL.squish)
        INSERT INTO execution_payloads (id, code, input_data, ctx, created_at, updated_at)
        SELECT id, code, input_data, ctx, created_at, updated_at
        FROM executions
        WHERE code IS NOT NULL OR input_data IS NOT NULL OR ctx IS NOT NULL
      SQL

      execute(<<~SQL.squish)
        UPDATE executions
        SET payload_id = id
        WHERE code IS NOT NULL OR input_data IS NOT NULL OR ctx IS NOT NULL
      SQL

      execute(<<~SQL.squish)
        SELECT setval(
          pg_get_serial_sequence('execution_payloads', 'id'),
          GREATEST((SELECT COALESCE(MAX(id), 0) FROM execution_payloads), 1)
        )
      SQL
    end
  end

  def down
    say_with_time "Restoring legacy columns from execution_payloads" do
      execute(<<~SQL.squish)
        UPDATE executions e
        SET code = p.code, input_data = p.input_data, ctx = p.ctx
        FROM execution_payloads p
        WHERE e.payload_id = p.id
      SQL
    end
  end
end
