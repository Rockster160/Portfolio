class CreateCronTask < ActiveRecord::Migration[7.1]
  def change
    create_table :cron_tasks do |t|
      t.belongs_to :user

      t.text :name
      t.text :cron
      t.text :command # (words or UUID or whatever)
      t.boolean :enabled, default: true
      t.datetime :last_trigger_at
      t.datetime :next_trigger_at

      t.timestamps
    end
  end
end
