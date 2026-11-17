# == Schema Information
#
# Table name: user_lists
#
#  id         :integer          not null, primary key
#  default    :boolean          default(FALSE)
#  is_owner   :boolean
#  sort_order :integer
#  list_id    :integer
#  user_id    :integer
#
FactoryBot.define do
  factory :user_list do
    user
    list
    is_owner { true }
    default { false }
  end
end
