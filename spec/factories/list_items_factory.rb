FactoryBot.define do
  factory :list_item do
    list
    sequence(:name) { |n| "Item #{n}" }
    important { false }
    permanent { false }
    category { "General" }
    sort_order { 0 }
  end
end
