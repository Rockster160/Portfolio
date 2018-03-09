class ListPowerups < ActiveRecord::Migration[5.0]
  def change
    add_column :lists, :important, :boolean, default: false
    add_column :list_items, :important, :boolean, default: false
    add_column :list_items, :permanent, :boolean, default: false
    add_column :list_items, :schedule, :string
    add_column :list_items, :category, :string
  end
end
