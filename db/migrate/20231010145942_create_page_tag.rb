class CreatePageTag < ActiveRecord::Migration[7.0]
  def change
    create_table :page_tags do |t|
      t.belongs_to :page, null: false, foreign_key: true
      t.belongs_to :tag, null: false, foreign_key: true

      t.timestamps
    end
  end
end
