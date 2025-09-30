FactoryBot.define do
  factory :section do
    list
    sequence(:name) { |n| "Section #{n}" }
    color { "#CCCCCC" }
    sort_order { 0 }
  end
end
