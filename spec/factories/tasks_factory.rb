FactoryBot.define do
  factory :task do
    user
    sequence(:name) { |n| "Task #{n}" }
    listener { "tell:noop" }
    code { "// noop" }
    enabled { true }
  end

  factory :execution do
    task
    user { task&.user || association(:user) }
    status { :success }
    started_at { Time.current }
    finished_at { started_at }
  end

  factory :jil_trigger_shape do
    user
    sequence(:scope) { |n| "scope#{n}" }
    keys { ["action"] }
    sample { { "action" => "String" } }
    observed_values { {} }
    seen_count { 1 }
    last_seen_at { Time.current }
  end
end
