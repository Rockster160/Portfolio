class CreateByteMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :byte_messages do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.integer :direction, null: false, default: 0
      t.integer :state, null: false, default: 0
      t.text :body
      t.string :external_ref
      t.jsonb :metadata, null: false, default: {}
      t.datetime :delivered_at
      t.timestamps
    end

    add_index :byte_messages, [:user_id, :created_at]
    add_index :byte_messages, :external_ref
  end
end
