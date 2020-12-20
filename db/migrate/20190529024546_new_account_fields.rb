class NewAccountFields < ActiveRecord::Migration[5.0]
  def change
    add_column :users, :dark_mode, :boolean
    add_column :users, :email, :string
  end
end
