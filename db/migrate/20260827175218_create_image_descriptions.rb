class CreateImageDescriptions < ActiveRecord::Migration[7.1]
  def change
    create_table :image_descriptions do |t|
      t.references :user, null: false, foreign_key: true
      # The BLOB is the picture's identity, not the message or the box it hangs
      # off. One photo filed into inventory from a chat is one picture in two
      # places, and describing it twice would put two different sentences on the
      # same image.
      t.references :blob, null: false, foreign_key: { to_table: :active_storage_blobs }, index: { unique: true }
      # Where it can be opened from again. A chat photo is reachable by message
      # id (`view_image`); an inventory one by its box.
      t.bigint :byte_message_id
      t.string :box_key

      t.text :body, null: false
      t.jsonb :tags, null: false, default: []
      # The moment the picture entered the house, carried separately because the
      # description is written behind the turn and a row created a minute later
      # would answer "the photo from Tuesday" with the wrong day.
      t.datetime :taken_at, null: false

      t.timestamps
    end

    add_index :image_descriptions, :byte_message_id
    add_index :image_descriptions, %i[user_id taken_at]
    add_index :image_descriptions, :tags, using: :gin
  end
end
