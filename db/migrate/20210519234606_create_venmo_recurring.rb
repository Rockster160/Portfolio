class CreateVenmoRecurring < ActiveRecord::Migration[5.0]
  def change
    create_table :venmo_recurrings do |t|
      t.string :to
      t.string :from
      t.integer :amount_cents
      t.string :note
      t.integer :day_of_month
      t.integer :hour_of_day
      t.boolean :active, default: true

      t.timestamps
    end
  end
end
