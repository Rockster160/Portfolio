class AddSortOrderToUserList < ActiveRecord::Migration[5.0]
  def change
    add_column :user_lists, :sort_order, :integer

    User.find_each do |user|
      user.user_lists.order(:id).each_with_index do |user_list, idx|
        user_list.update(sort_order: idx)
      end
    end
  end
end
