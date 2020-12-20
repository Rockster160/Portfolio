class CreateLitterTextReminder < ActiveRecord::Migration
  def change
    create_table :litter_text_reminders do |t|
      t.integer :turn, default: 0

      t.timestamps
    end
  end
end
