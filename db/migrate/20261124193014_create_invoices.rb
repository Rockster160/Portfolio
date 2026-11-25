class CreateInvoices < ActiveRecord::Migration[8.0]
  def change
    create_table :invoices do |t|
      t.belongs_to :user, null: false, foreign_key: true
      t.text :number, null: false
      t.date :issued_on, null: false
      t.date :due_on
      t.text :sender
      t.text :recipient
      t.jsonb :items, null: false, default: []
      t.text :notes

      t.timestamps
    end
  end
end
