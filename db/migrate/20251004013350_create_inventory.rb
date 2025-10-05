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

      t.jsonb :hierarchy, null: false, default: []

      t.timestamps
    end

    create_table :box_items do |t|
      t.references :user, null: false, foreign_key: true
      t.references :box, null: false, foreign_key: { to_table: :boxes }
      t.text :name, null: false
      t.text :description
      t.integer :sort_order, null: false
      t.jsonb :data, null: false, default: {}
      t.text :notes

      t.jsonb :hierarchy, null: false, default: []

      t.timestamps
    end

    create_table :inventory_tags do |t|
      t.references :user, null: false, foreign_key: true
      t.text :name, null: false
      t.text :color, null: false

      t.timestamps
    end

    create_table :box_tags do |t|
      t.references :box, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true

      t.timestamps
    end

    create_table :item_tags do |t|
      t.references :item, null: false, foreign_key: { to_table: :box_items }
      t.references :tag, null: false, foreign_key: true

      t.timestamps
    end
  end
end
