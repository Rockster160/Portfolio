class CreateAvatar < ActiveRecord::Migration[5.0]
  def change
    create_table :avatars do |t|
      t.belongs_to :user
      t.string :ears_url
      t.string :eyes_url
      t.string :body_url
      t.string :nose_url
      t.string :beard_url
      t.string :belt_url
      t.string :feet_url
      t.string :legs_url
      t.string :hands_url
      t.string :torso_url
      t.string :hair_url
      t.string :arms_url
      t.string :neck_url
      t.string :head_url
      t.string :weapons_url
      t.string :back_url

      t.timestamps
    end
  end
end
