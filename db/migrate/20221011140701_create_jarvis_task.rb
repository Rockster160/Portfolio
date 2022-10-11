class CreateJarvisTask < ActiveRecord::Migration[7.0]
  def change
    create_table :jarvis_tasks do |t|
      t.belongs_to :user
      t.text :name
      t.text :cron
      t.integer :trigger # enum
      t.text :last_result
      t.jsonb :last_ctx
      t.datetime :last_trigger_at
      t.datetime :next_trigger_at
      t.jsonb :tasks

      t.timestamps
    end

    create_table :jarvis_caches do |t|
      t.belongs_to :user
      t.jsonb :data

      t.timestamps
    end
  end
end
