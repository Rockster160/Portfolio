class RemoveUnneededIndexes < ActiveRecord::Migration[7.1]
  def change
    remove_index :emails, name: "index_emails_on_mail_id", column: :mail_id
    remove_index :list_builders, name: "index_list_builders_on_user_id", column: :user_id
    remove_index :meal_builders, name: "index_meal_builders_on_user_id", column: :user_id
    remove_index :shared_pages, name: "index_shared_pages_on_page_id", column: :page_id
    remove_index :shared_tasks, name: "index_shared_tasks_on_task_id", column: :task_id
    remove_index :user_push_subscriptions, name: "index_user_push_subscriptions_on_user_id", column: :user_id
  end
end
