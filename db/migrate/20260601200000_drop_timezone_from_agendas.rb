class DropTimezoneFromAgendas < ActiveRecord::Migration[7.1]
  def change
    remove_column :agendas, :timezone, :string
  end
end
