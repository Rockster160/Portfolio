class CreateAgendaNotificationSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :agenda_notification_settings do |t|
      t.references :user, null: false, foreign_key: true
      t.references :agenda, null: false, foreign_key: true

      # 2-axis matrix: kind (task/event/trigger) × recurrence (recurring/oneoff).
      # Defaults: tasks + events notify (both recurrence types), triggers do
      # NOT (they already fire their own Jil/Jarvis action via
      # FireDueAgendaTriggersWorker — push is opt-in).
      t.boolean :notify_task_oneoff,     null: false, default: true
      t.boolean :notify_task_recurring,  null: false, default: true
      t.boolean :notify_event_oneoff,    null: false, default: true
      t.boolean :notify_event_recurring, null: false, default: true
      t.boolean :notify_trigger_oneoff,     null: false, default: false
      t.boolean :notify_trigger_recurring,  null: false, default: false

      t.timestamps
    end

    add_index :agenda_notification_settings, [:user_id, :agenda_id], unique: true
  end
end
