class AddEnabledToJarvisTask < ActiveRecord::Migration[7.0]
  def change
    add_column :jarvis_tasks, :enabled, :boolean, default: true
  end
end
