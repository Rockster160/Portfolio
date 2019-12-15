class AddDefaultToList < ActiveRecord::Migration[5.0]
  def change
    add_column :user_lists, :default, :boolean, default: false

    User.find_each do |user|
      user.user_lists.order(sort_order: :asc).first&.update(default: true)
    end
  end
end
