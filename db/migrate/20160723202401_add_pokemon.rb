class AddPokemon < ActiveRecord::Migration
  def change
    create_table :pokemons do |t|
      t.integer :pokedex_id
      t.string :lat
      t.string :lon
      t.string :name
      t.datetime :expires_at

      t.timestamps
    end
  end
end
