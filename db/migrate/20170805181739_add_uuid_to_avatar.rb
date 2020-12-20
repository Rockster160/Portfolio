class AddUuidToAvatar < ActiveRecord::Migration[5.0]
  def change
    add_column :avatars, :uuid, :integer
    Avatar.find_each do |avatar|
      avatar.send(:set_uuid)
      avatar.save
    end
    change_column_null :avatars, :uuid, false
  end
end
