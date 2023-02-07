# == Schema Information
#
# Table name: jarvis_tasks
#
#  id              :bigint           not null, primary key
#  cron            :text
#  last_ctx        :jsonb
#  last_result     :text
#  last_trigger_at :datetime
#  name            :text
#  next_trigger_at :datetime
#  tasks           :jsonb
#  trigger         :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :bigint
#
class JarvisTask < ApplicationRecord
  belongs_to :user, required: true
  serialize :tasks, SafeJsonSerializer
  serialize :last_ctx, SafeJsonSerializer

  scope :cron, -> { where(trigger: nil) }

  enum trigger: {
    action_event:      1,
    tell:              2,
    list:              3,
    email:             4,
    webhook:           5,
    websocket:         6,
    websocket_expires: 7,
    integration:       8,
    failed_task:       9,
  }

  def humanized_schedule
    return trigger.titleize if trigger.present?

    cron
  end
end
