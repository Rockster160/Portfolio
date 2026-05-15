FactoryBot.define do
  factory :agenda do
    sequence(:name) { |n| "Agenda #{n}" }
    color { "#0160FF" }
    user
  end

  factory :agenda_schedule do
    sequence(:name) { |n| "Schedule #{n}" }
    kind { "task" }
    start_time { "09:00" }
    starts_on { Date.current }
    recurrence { { "freq" => "daily" } }
    agenda
  end

  factory :agenda_item do
    sequence(:name) { |n| "Item #{n}" }
    kind { "task" }
    start_at { Time.current }
    agenda
  end
end
