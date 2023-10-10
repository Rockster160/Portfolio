class CreateFolders < ActiveRecord::Migration[7.0]
  def change
    create_table :folders do |t|
      t.belongs_to :user
      t.belongs_to :folder
      t.text :name
      t.text :parameterized_name, index: true
      t.integer :sort_order

      t.timestamps
    end

    create_table :folder_tags do |t|
      t.belongs_to :folder
      t.belongs_to :tag

      t.timestamps
    end

    add_reference :pages, :folder
    add_column :pages, :parameterized_name, :text, index: true
    add_column :pages, :sort_order, :integer
    rename_column :pages, :title, :name
  end
end
