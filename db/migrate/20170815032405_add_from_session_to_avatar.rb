class AddFromSessionToAvatar < ActiveRecord::Migration[5.0]
  def change
    add_column :avatars, :from_session, :boolean
  end
end
