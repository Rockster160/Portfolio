class AddWhoDidItToChores < ActiveRecord::Migration[7.1]
  def change
    add_column :chores, :who_did_it, :jsonb, default: {}, null: false
  end
end
