# == Schema Information
#
# Table name: app_live_activities
#
#  id            :bigint           not null, primary key
#  ended_at      :datetime
#  kind          :text             default("timer"), not null
#  push_token    :text
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  activity_id   :text             not null
#  app_device_id :bigint           not null
#  ref_id        :text
#
class AppLiveActivity < ApplicationRecord
  belongs_to :app_device

  scope :live, -> { where(ended_at: nil) }
  scope :for_ref, ->(kind, ref_id) { live.where(kind: kind, ref_id: ref_id.to_s) }

  def end!
    update!(ended_at: Time.current)
  end
end
