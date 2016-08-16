class AddRegexToReminders < ActiveRecord::Migration
  def change
    add_column :litter_text_reminders, :regex, :string
    add_column :litter_text_reminders, :message, :string

    rem = LitterTextReminder.first
    rem.update(regex: 'cat|kit|lit|box', message: "It's your turn to do the litter box! Respond with 'Cat', or 'Litter Box' when you have completed the task.")
    LitterTextReminder.create(regex: 'dish|sink', message: "It's your turn to do the Dishes! Respond with 'Dishes!' when you have completed the task.")
  end
end
