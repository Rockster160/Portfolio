FactoryBot.define do
  factory :timer do
    user
    name { "" }
    kind { :countdown }
    duration_ms { 60_000 }
    callbacks { [] }
  end

  factory :timer_page do
    user
    name { "Morning" }
    sequence(:slug) { |n| "morning-#{n}" }
    layout_mode { :auto }
    sections { [] }
  end

  factory :timer_quick_button do
    user
    duration_seconds { 300 }
    sort_order { 0 }
  end

  factory :timer_share_token do
    user
    association :timer, factory: :timer
    access_mode { :view_only }
  end
end
