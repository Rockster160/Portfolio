class AddTriggerToJarvisTask < ActiveRecord::Migration[7.1]
  def change
    add_column :jarvis_tasks, :listener, :text

    reversible do |migration|
      migration.up do
        JarvisTask.find_each { |t| t.update(listener: t.trigger) }
      end
    end
  end
end
