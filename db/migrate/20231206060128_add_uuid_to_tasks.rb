class AddUuidToTasks < ActiveRecord::Migration[7.0]
  def change
    enable_extension "uuid-ossp"
    add_column :jarvis_tasks, :uuid, :uuid, default: -> { "uuid_generate_v4()" }
    JarvisTask.find_each do |task|
      task.update(uuid: SecureRandom.uuid)
    end
  end
end
