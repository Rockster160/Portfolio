class CreateSections < ActiveRecord::Migration[6.0]
  def change
    create_table :sections do |t|
      t.text :name, null: false
      t.text :color, null: false
      t.integer :sort_order, null: false
      t.belongs_to :list, null: false, foreign_key: true, index: true

      t.timestamps
    end

    add_reference :list_items, :section, foreign_key: true, null: true
  end
end
