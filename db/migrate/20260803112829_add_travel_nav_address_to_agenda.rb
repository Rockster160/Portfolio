class AddTravelNavAddressToAgenda < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_items, :travel_nav_address, :string
    add_column :agenda_schedules, :travel_nav_address, :string
  end
end
