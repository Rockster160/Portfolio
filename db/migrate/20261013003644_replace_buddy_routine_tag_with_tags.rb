class ReplaceBuddyRoutineTagWithTags < ActiveRecord::Migration[7.1]
  def up
    add_column :buddy_routines, :tags, :text, array: true, default: [], null: false
    execute(<<~SQL.squish)
      UPDATE buddy_routines SET tags = ARRAY[btrim(tag)]
      WHERE tag IS NOT NULL AND btrim(tag) <> ''
    SQL
    remove_column :buddy_routines, :tag
  end

  def down
    add_column :buddy_routines, :tag, :string
    execute("UPDATE buddy_routines SET tag = tags[1] WHERE array_length(tags, 1) > 0")
    remove_column :buddy_routines, :tags
  end
end
