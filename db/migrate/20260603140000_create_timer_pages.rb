class CreateTimerPages < ActiveRecord::Migration[7.1]
  def change
    create_table :timer_pages do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.text    :name, null: false, default: ""
      t.text    :slug, null: false
      t.integer :sort_order, null: false, default: 0
      t.integer :layout_mode, null: false, default: 0
      t.jsonb   :sections, null: false, default: []
      t.timestamps precision: 6
    end

    add_index :timer_pages, [:user_id, :slug], unique: true
  end
end
