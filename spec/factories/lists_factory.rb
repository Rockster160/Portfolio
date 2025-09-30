FactoryBot.define do
  factory :list do
    sequence(:name) { |n| "List #{n}" }
    description { "A test list." }
    important { false }
    show_deleted { false }

    transient do
      user { nil }
    end

    after(:create) do |list, evaluator|
      FactoryBot.create(:user_list, user: evaluator.user, list: list) if evaluator.user
    end
  end
end
