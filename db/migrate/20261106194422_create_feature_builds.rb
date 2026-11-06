class CreateFeatureBuilds < ActiveRecord::Migration[7.1]
  def change
    create_table(:feature_builds) { |t|
      t.references :user, null: false, foreign_key: true
      t.references :byte_conversation, foreign_key: { on_delete: :nullify }
      t.references :byte_message, foreign_key: { on_delete: :nullify }
      t.string :title, null: false
      t.text :request, null: false
      t.integer :status, null: false, default: 0
      t.string :branch
      t.string :session_id
      t.string :rc_url
      t.integer :pr_number, index: true
      t.string :pr_url
      t.text :error
      t.jsonb :feedback, null: false, default: []
      t.datetime :finished_at

      t.timestamps
    }
  end
end
