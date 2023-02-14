class AddInputOutputToTask < ActiveRecord::Migration[7.0]
  def change
    add_column :jarvis_tasks, :input, :text
    add_column :jarvis_tasks, :output_type, :integer, default: 1
  end
end
