class ReplaceChoreCreditButtonTagWithTags < ActiveRecord::Migration[7.1]
  def up
    add_column :chore_credit_buttons, :tags, :text, array: true, default: [], null: false
    execute(<<~SQL.squish)
      UPDATE chore_credit_buttons SET tags = ARRAY[btrim(tag)]
      WHERE tag IS NOT NULL AND btrim(tag) <> ''
    SQL
    remove_index :chore_credit_buttons, name: :index_chore_credit_buttons_on_chore_household_id_and_tag
    remove_column :chore_credit_buttons, :tag
  end

  def down
    add_column :chore_credit_buttons, :tag, :text
    execute("UPDATE chore_credit_buttons SET tag = tags[1] WHERE array_length(tags, 1) > 0")
    add_index :chore_credit_buttons, [:chore_household_id, :tag],
      name: :index_chore_credit_buttons_on_chore_household_id_and_tag
    remove_column :chore_credit_buttons, :tags
  end
end
