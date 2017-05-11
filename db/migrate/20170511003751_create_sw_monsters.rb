class CreateSwMonsters < ActiveRecord::Migration[5.0]
  def change
    create_table :monsters do |t|
      t.string :name
      t.string :url
      t.integer :element # Enum

      t.integer :health # HP
      t.integer :attack # ATK
      t.integer :defense # DEF
      t.integer :speed # SPD
      t.integer :crit_rate # CRI Rate
      t.integer :crit_damage # CRI DMG
      t.integer :resistance # RES
      t.integer :accuracy # ACC
    end

    create_table :monster_skills do |t|
      t.belongs_to :monster
      t.string :name
      t.text :description
      t.string :stat
    end
  end
end
