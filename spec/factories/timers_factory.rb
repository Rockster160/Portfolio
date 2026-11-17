# == Schema Information
#
# Table name: timers
#
#  id                  :bigint           not null, primary key
#  archived_at         :datetime
#  callbacks           :jsonb            not null
#  color               :text
#  confirmed_at        :datetime
#  dial_config         :jsonb            not null
#  dial_step_index     :integer          default(0), not null
#  disabled            :boolean          default(FALSE), not null
#  duration_ms         :bigint
#  end_at              :datetime
#  fire_jid            :string
#  fire_scheduled_for  :datetime
#  fired_at            :datetime
#  height              :integer          default(0), not null
#  kind                :integer          default("countdown"), not null
#  max_value           :integer
#  metadata            :jsonb            not null
#  min_value           :integer
#  name                :text             default(""), not null
#  paused_at           :datetime
#  paused_remaining_ms :bigint
#  pos_x               :integer          default(0), not null
#  pos_y               :integer          default(0), not null
#  repeat              :boolean          default(FALSE), not null
#  repeat_count        :integer          default(0), not null
#  require_confirm_tap :boolean          default(FALSE), not null
#  reset_value         :integer          default(0), not null
#  started_at          :datetime
#  step                :integer          default(1), not null
#  value               :integer          default(0), not null
#  width               :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  section_id          :integer
#  timer_page_id       :bigint
#  user_id             :bigint           not null
#
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
