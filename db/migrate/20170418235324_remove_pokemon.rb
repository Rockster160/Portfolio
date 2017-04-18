class RemovePokemon < ActiveRecord::Migration
  def change
    drop_table :pokemons
    drop_table :pokewalkers
  end
end
