class AddLists < ActiveRecord::Migration
  def change
    create_table :lists do |t|
      t.string :name

      t.timestamps
    end
    create_table :list_items do |t|
      t.string :name
      t.belongs_to :list, foreign_key: true, index: true

      t.timestamps
    end
  end
end
