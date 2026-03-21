class RemoveShareTokenFromPages < ActiveRecord::Migration[7.1]
  def change
    remove_column :pages, :share_token, :string
  end
end
