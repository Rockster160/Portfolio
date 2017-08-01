class AddLocationToAvatar < ActiveRecord::Migration[5.0]
  def change
    add_column :avatars, :location_x, :integer
    add_column :avatars, :location_y, :integer
    add_column :avatars, :timestamp, :string
  end
end
