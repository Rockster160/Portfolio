class AddShareTokenToPages < ActiveRecord::Migration[7.1]
  def change
    add_column :pages, :share_token, :string
    add_index :pages, :share_token, unique: true
  end
end
