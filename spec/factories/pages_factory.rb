FactoryBot.define do
  factory :page do
    sequence(:name) { |n| "Page #{n}" }
    content { "hello" }
    user
  end
end
