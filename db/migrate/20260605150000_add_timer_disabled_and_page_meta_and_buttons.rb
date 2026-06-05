class AddTimerDisabledAndPageMetaAndButtons < ActiveRecord::Migration[7.1]
  def change
    add_column :timers, :disabled, :boolean, default: false, null: false

    add_column :timer_pages, :meta, :jsonb, default: {}, null: false

    create_table :timer_page_buttons do |t|
      t.references :timer_page, null: false, foreign_key: { on_delete: :cascade }
      t.text :label, null: false, default: ""
      t.text :color
      t.text :target_url, null: false
      t.integer :sort_order, default: 0, null: false
      t.timestamps precision: 6
    end

    add_index :timer_page_buttons, [:timer_page_id, :sort_order]
  end
end
