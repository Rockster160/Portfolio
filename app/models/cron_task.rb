# == Schema Information
#
# Table name: cron_tasks
#
#  id              :bigint           not null, primary key
#  command         :text
#  cron            :text
#  enabled         :boolean          default(TRUE)
#  last_trigger_at :datetime
#  name            :text
#  next_trigger_at :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :bigint
#
class CronTask < ApplicationRecord
  belongs_to :user

  before_save :set_next_cron

  scope :enabled, -> { where(enabled: true) }

  def disabled?
    !enabled?
  end

  private

  def set_next_cron
    if enabled?
      self.next_trigger_at = ::CronParse.next(cron)
    else
      self.next_trigger_at = nil
    end
  end
end
