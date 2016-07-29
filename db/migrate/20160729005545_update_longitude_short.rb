class UpdateLongitudeShort < ActiveRecord::Migration
  def change
    rename_column :pokemons, :lon, :lng
  end
end
