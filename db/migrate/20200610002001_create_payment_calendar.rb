class CreatePaymentCalendar < ActiveRecord::Migration[5.0]
  def change
    create_table :payment_schedules do |t|
      t.belongs_to :user
      t.string :name
      t.string :description
      t.integer :cost_in_pennies

      t.datetime :recurrence_start
      t.integer :recurrence_date
      t.integer :recurrence_wday # enum, weekday
      t.integer :recurrence_type # daily, weekly, biweekly, monthly, bimonthly, quarterly, semiyearly, biyearly

      t.timestamps
    end

    create_table :payment_charges do |t|
      t.belongs_to :user

      t.text :raw
      t.string :cost_in_pennies
      t.datetime :occurred_at

      t.timestamps
    end
  end
end
