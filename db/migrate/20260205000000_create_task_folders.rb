class CreateTaskFolders < ActiveRecord::Migration[7.1]
  def change
    create_table :task_folders do |t|
      t.belongs_to :user, null: false, foreign_key: true
      t.belongs_to :parent, foreign_key: { to_table: :task_folders }, null: true
      t.text :name, null: false
      t.integer :sort_order
      t.boolean :collapsed, default: false
      t.timestamps
    end

    add_reference :tasks, :task_folder, foreign_key: { to_table: :task_folders }, null: true
  end
end
