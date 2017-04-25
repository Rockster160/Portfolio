class CreateUserLists < ActiveRecord::Migration[5.0]
  def change
    create_table :user_lists do |t|
      t.belongs_to :user
      t.belongs_to :list
      t.boolean :is_owner
    end

    reversible do |migration|
      migration.up do
        user = User.by_username("Rockster160").first
        user ||= User.create(username: "Rockster160", password: "password")
        List.find_each do |list|
          user.user_lists.create(list_id: list.id, is_owner: true)
        end
      end
    end
  end
end
