FactoryBot.define do
  factory :chore do
    sequence(:name) { |n| "Chore #{n}" }
    short_name { name }
    icon { "🧹" }
    aliases { [] }
    reward_pebbles { 5 }
    association :created_by_user, factory: :user
  end

  factory :chore_completion do
    chore
    user
    completed_at { Time.current }
    day_key { ChoreDay.current(user) }
    base_pebbles { 5 }
    paid_pebbles { 5 }
  end

  factory :chore_goal do
    sequence(:name) { |n| "Goal #{n}" }
    kind { :pebbles }
    target_value { 100 }
    user
  end

  factory :chore_streak_bonus do
    sequence(:name) { |n| "Bonus #{n}" }
    kind { :daily_pebbles }
    config { { "levels" => [{ "threshold" => 20, "multiplier" => 2, "bonus_pebbles" => 0 }] } }
    user
  end

  factory :chore_withdrawal do
    amount_pebbles { 10 }
    user
  end

  factory :chore_transfer do
    amount_pebbles { 5 }
    association :from_user, factory: :user
    association :to_user,   factory: :user
  end

  factory :chore_share do
    user
    association :shared_with_user, factory: :user
  end

  factory :chore_hot_pick do
    chore
    day_key { ChoreDay.current }
    multiplier { 2.0 }
  end
end
