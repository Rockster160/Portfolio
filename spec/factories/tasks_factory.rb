# == Schema Information
#
# Table name: tasks
#
#  id              :bigint           not null, primary key
#  archived_at     :datetime
#  buddy_enabled   :boolean          default(FALSE), not null
#  code            :text
#  cron            :text
#  description     :text
#  enabled         :boolean          default(TRUE)
#  last_status     :integer
#  last_trigger_at :datetime
#  listener        :text
#  name            :text
#  next_trigger_at :datetime
#  short_key       :text
#  sort_order      :integer
#  tree_order      :integer
#  uuid            :uuid
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  task_folder_id  :bigint
#  user_id         :bigint
#
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
