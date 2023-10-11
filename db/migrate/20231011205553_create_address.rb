class CreateAddress < ActiveRecord::Migration[7.0]
  def change
    create_table :addresses do |t|
      t.belongs_to :user
      t.belongs_to :contact
      t.boolean :primary
      t.text :icon
      t.text :label
      t.text :street
      t.float :lat
      t.float :lng

      t.timestamps
    end

    reversible do |migration|
      migration.up do
        Contact.where.not(address: nil).find_each do |contact|
          contact.addresses.create(
            primary: true,
            user: contact.user,
            street: contact.address,
            lat: contact.lat,
            lng: contact.lng,
          )
        end
      end
    end
  end
end
