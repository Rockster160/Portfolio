class CreateInventory < ActiveRecord::Migration[7.1]
  def change
    create_table :boxes do |t|
      t.references :user, null: false, foreign_key: true
      t.references :parent, null: true, foreign_key: { to_table: :boxes }
      t.text :name, null: false
      t.text :description
      t.integer :sort_order, null: false
      t.jsonb :data, null: false, default: {}
      t.text :notes
      t.boolean :empty, null: false, default: true

      t.jsonb :hierarchy_ids, null: false, default: []
      t.jsonb :hierarchy_data, null: false, default: []

      t.timestamps
    end
  end
end
