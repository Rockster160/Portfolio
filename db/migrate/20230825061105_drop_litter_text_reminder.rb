class DropLitterTextReminder < ActiveRecord::Migration[7.0]
  def change
    drop_table :litter_text_reminders
  end
end
