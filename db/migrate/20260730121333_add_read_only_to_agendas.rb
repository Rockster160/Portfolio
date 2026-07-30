class AddReadOnlyToAgendas < ActiveRecord::Migration[7.1]
  def change
    add_column :agendas, :read_only, :boolean, default: false, null: false
  end
end
