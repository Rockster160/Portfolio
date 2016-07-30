class CreatePokeWalker < ActiveRecord::Migration
  def change
    create_table :pokewalkers do |t|
      t.string :username
      t.string :password
      t.string :last_loc
      t.boolean :banned, default: false
      t.string :monitor_loc_start
      t.string :monitor_loc_end

      t.timestamps
    end
  end
end
