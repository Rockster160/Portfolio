# == Schema Information
#
# Table name: agendas
#
#  id                 :bigint           not null, primary key
#  color              :string
#  name               :string           not null
#  parameterized_name :string           not null
#  read_only          :boolean          default(FALSE), not null
#  sort_order         :integer
#  source             :integer          default("user"), not null
#  sync_reason        :string
#  sync_token         :text
#  synced_at          :datetime
#  watch_expires_at   :datetime
#  watch_failed_at    :datetime
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  external_id        :text
#  google_account_id  :bigint
#  user_id            :bigint           not null
#  watch_channel_id   :text
#  watch_resource_id  :text
#
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
