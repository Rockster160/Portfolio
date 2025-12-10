class SwitchBoxesToParentParamKey < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    # 1. Add new column
    add_column :boxes, :parent_key, :text

    # 2. Backfill parent_key from existing parent_id
    execute <<~SQL
      UPDATE boxes AS child
      SET parent_key = parent.param_key
      FROM boxes AS parent
      WHERE child.parent_id = parent.id
    SQL

    # 3. Ensure top-level boxes have NULL parent_key
    execute <<~SQL
      UPDATE boxes
      SET parent_key = NULL
      WHERE parent_id IS NULL
    SQL

    add_index :boxes, :parent_key

    # 3. Drop old column
    remove_column :boxes, :parent_id

    Box.full_reset
  end

  def down
    # Reverse migration: restore parent_id from parent_key

    add_column :boxes, :parent_id, :bigint

    execute <<~SQL
      UPDATE boxes AS child
      SET parent_id = parent.id
      FROM boxes AS parent
      WHERE child.parent_key = parent.param_key
    SQL

    # Top-level boxes -> NULL parent_id
    execute <<~SQL
      UPDATE boxes
      SET parent_id = NULL
      WHERE parent_key IS NULL
    SQL

    remove_index :boxes, :parent_key
    remove_column :boxes, :parent_key
  end
end
