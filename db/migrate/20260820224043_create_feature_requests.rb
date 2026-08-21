class CreateFeatureRequests < ActiveRecord::Migration[7.1]
  def change
    create_table(:feature_requests) { |t|
      t.references :user, null: false, foreign_key: true
      t.references :byte_conversation, foreign_key: true
      t.references :byte_message, foreign_key: true

      t.string  :title,  null: false
      t.text    :body,   null: false
      t.integer :status, null: false, default: 0
      t.datetime :seen_at

      t.timestamps
    }

    add_index :feature_requests, [:status, :created_at]
  end
end
