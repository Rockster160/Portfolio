class CreateProductionScripts < ActiveRecord::Migration[7.1]
  def change
    create_table(:production_scripts) { |t|
      t.references :user, null: false, foreign_key: true
      t.references :feature_build, foreign_key: true
      t.string :title, null: false
      t.text :code, null: false
      t.string :commit_sha, null: false
      t.integer :status, null: false, default: 0
      t.string :edited_by, null: false
      t.datetime :approved_at
      t.datetime :started_at
      t.datetime :ran_at
      t.integer :exit_status
      t.text :output

      t.timestamps
    }
    add_index :production_scripts, :status
  end
end
