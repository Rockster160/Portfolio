class RemoveVenmo < ActiveRecord::Migration[7.0]
  def change
    drop_table :venmos
  end
end
