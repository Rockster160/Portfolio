class ReplaceChoreTagWithTags < ActiveRecord::Migration[7.1]
  def up
    add_column :chores, :tags, :text, array: true, default: [], null: false
    execute(<<~SQL.squish)
      UPDATE chores SET tags = ARRAY[btrim(tag)]
      WHERE tag IS NOT NULL AND btrim(tag) <> ''
    SQL
    remove_index :chores, name: :index_chores_on_chore_household_id_and_tag
    remove_column :chores, :tag
  end

  def down
    add_column :chores, :tag, :text
    execute("UPDATE chores SET tag = tags[1] WHERE array_length(tags, 1) > 0")
    add_index :chores, [:chore_household_id, :tag], name: :index_chores_on_chore_household_id_and_tag
    remove_column :chores, :tags
  end
end
