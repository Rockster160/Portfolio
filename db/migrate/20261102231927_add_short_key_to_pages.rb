class AddShortKeyToPages < ActiveRecord::Migration[7.1]
  CHARS = [*"A".."Z"] - ["I", "O"]

  class MigrationPage < ActiveRecord::Base
    self.table_name = "pages"
  end

  def up
    add_column :pages, :short_key, :text
    add_index :pages, :short_key, unique: true

    MigrationPage.reset_column_information
    taken = Set.new
    MigrationPage.where(short_key: nil).find_each { |page|
      key = loop {
        candidate = Array.new(4) { CHARS.sample }.join
        break candidate if taken.add?(candidate)
      }
      page.update_column(:short_key, key)
    }
  end

  def down
    remove_index :pages, :short_key
    remove_column :pages, :short_key
  end
end
