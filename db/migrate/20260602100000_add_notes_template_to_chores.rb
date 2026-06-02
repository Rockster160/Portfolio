class AddNotesTemplateToChores < ActiveRecord::Migration[7.1]
  def change
    add_column :chores, :notes_template, :text
  end
end
