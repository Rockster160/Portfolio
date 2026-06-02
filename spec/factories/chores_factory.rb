FactoryBot.define do
  factory :chore_household do
    name { "Household" }
    association :owner_user, factory: :user
  end

  factory :chore_household_membership do
    chore_household
    user
    role { :manager }
  end

  factory :chore do
    sequence(:name) { |n| "Chore #{n}" }
    short_name { name }
    icon { "🧹" }
    aliases { [] }
    reward_pebbles { 5 }
    association :created_by_user, factory: :user
    chore_household {
      ChoreHouseholdMembership.where(user_id: created_by_user.id).first&.chore_household ||
        association(:chore_household, owner_user: created_by_user)
    }

    after(:create) do |chore, _|
      chore.created_by_user.reload if chore.created_by_user.chore_household_id.nil?
    end
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
    transient do
      user { nil }
    end
    sequence(:name) { |n| "Bonus #{n}" }
    kind { :daily_pebbles }
    config { { "levels" => [{ "threshold" => 20, "multiplier" => 2, "bonus_pebbles" => 0 }] } }
    chore_household {
      if user
        ChoreHouseholdMembership.where(user_id: user.id).first&.chore_household ||
          association(:chore_household, owner_user: user)
      else
        association(:chore_household)
      end
    }
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

  factory :chore_hot_pick do
    chore
    day_key { ChoreDay.current }
    multiplier { 2.0 }
  end
end
