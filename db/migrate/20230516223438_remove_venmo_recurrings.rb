class RemoveVenmoRecurrings < ActiveRecord::Migration[7.0]
  def change
    drop_table :venmo_recurrings
  end
end
