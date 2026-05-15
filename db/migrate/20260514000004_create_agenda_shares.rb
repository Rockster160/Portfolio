class CreateAgendaShares < ActiveRecord::Migration[7.1]
  def change
    create_table :agenda_shares do |t|
      t.references :agenda, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :permission, null: false, default: 0
      t.timestamps
    end

    add_index :agenda_shares, [:agenda_id, :user_id], unique: true
  end
end
