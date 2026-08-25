FactoryBot.define do
  factory :box do
    user
    sequence(:name) { |n| "Box #{n}" }
  end
end
