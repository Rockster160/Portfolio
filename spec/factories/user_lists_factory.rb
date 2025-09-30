FactoryBot.define do
  factory :user_list do
    user
    list
    is_owner { true }
    default { false }
  end
end
