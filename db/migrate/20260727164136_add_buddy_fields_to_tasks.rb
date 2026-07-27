class AddBuddyFieldsToTasks < ActiveRecord::Migration[7.1]
  def change
    # Plain-language explanation of what the task does. Shown under the
    # title on the index and shipped to Buddy so it can judge relevance
    # from more than a cryptic name ("Great Fan", "ESP Button").
    add_column :tasks, :description, :text

    # Opt-in gate for assistant invocation. Orthogonal to shared_tasks
    # (which controls which HUMANS see a task) - this controls whether
    # Buddy may fire it on the owner's or a sharee's behalf. Defaults
    # false so the ~380-task index starts empty and only deliberately
    # enabled tasks reach the prompt.
    add_column :tasks, :buddy_enabled, :boolean, default: false, null: false
    add_index :tasks, :buddy_enabled, where: "buddy_enabled"
  end
end
