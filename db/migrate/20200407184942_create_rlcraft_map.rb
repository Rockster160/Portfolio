class CreateRlcraftMap < ActiveRecord::Migration[5.0]
  def change
    create_table :rlcraft_map_locations do |t|
      t.integer :x_coord
      t.integer :y_coord
      t.string :title
      t.string :location_type
      t.string :description

      t.timestamps
    end
  end
end
