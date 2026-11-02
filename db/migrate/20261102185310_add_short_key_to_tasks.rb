class AddShortKeyToTasks < ActiveRecord::Migration[7.1]
  CHARS = [*"A".."Z"] - ["I", "O"]

  class MigrationTask < ActiveRecord::Base
    self.table_name = "tasks"
  end

  def up
    add_column :tasks, :short_key, :text
    add_index :tasks, :short_key, unique: true

    MigrationTask.reset_column_information
    taken = Set.new
    MigrationTask.where(short_key: nil).find_each { |task|
      key = loop {
        candidate = Array.new(4) { CHARS.sample }.join
        break candidate if taken.add?(candidate)
      }
      task.update_column(:short_key, key)
    }
  end

  def down
    remove_index :tasks, :short_key
    remove_column :tasks, :short_key
  end
end
