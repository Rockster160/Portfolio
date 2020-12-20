class CreateAvatar < ActiveRecord::Migration[5.0]
  def change
    create_table :avatars do |t|
      t.belongs_to :user

      t.timestamps
    end
    create_table :avatar_clothes do |t|
      t.belongs_to :avatar
      t.string :gender
      t.string :placement
      t.string :garment
      t.string :color

      t.timestamps
    end
  end
end
