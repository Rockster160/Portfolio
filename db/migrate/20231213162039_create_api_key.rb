class CreateAPIKey < ActiveRecord::Migration[7.0]
  def change
    create_table :api_keys do |t|
      t.belongs_to :user
      t.text :name
      t.text :key

      t.timestamps
    end
  end
end
