class CreateClimbs < ActiveRecord::Migration[7.0]
  def change
    create_table :climbs do |t|
      t.belongs_to :user
      t.text :data

      t.timestamps
    end
  end
end
