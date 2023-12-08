class CreateJilUsage < ActiveRecord::Migration[7.0]
  def change
    create_table :jil_usages do |t|
      t.belongs_to :user
      t.integer :executions
      t.date :date
      t.integer :icount
      t.jsonb :data

      t.timestamps
    end

    add_index :jil_usages, [:user_id, :date], unique: true
  end
end
