# == Schema Information
#
# Table name: buddy_announcements
#
#  id           :bigint           not null, primary key
#  body         :text             not null
#  delivered_at :datetime
#  expires_at   :datetime
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null

#
# Something to tell somebody, folded into their next Today briefing and said in
# their companion's own words rather than read out verbatim.
#
# One row per person even when the same thing goes to everyone: they read their
# briefings at different times, and a shared row would be marked delivered by
# whoever got up first.
class BuddyAnnouncement < ApplicationRecord
  belongs_to :user

  MAX_BODY = 500

  validates :body, presence: true, length: { maximum: MAX_BODY }

  scope :undelivered, -> { where(delivered_at: nil) }
  scope :unexpired,   ->(now=Time.current) { where("expires_at IS NULL OR expires_at > ?", now) }

  # What the next briefing should carry. Oldest first, so a queue of two reads
  # in the order they were written.
  scope :pending, ->(now=Time.current) { undelivered.unexpired(now).order(created_at: :asc) }

  def delivered? = delivered_at.present?

  def expired?(now=Time.current) = expires_at.present? && expires_at <= now

  # Where it got to, for the admin list.
  def state(now=Time.current)
    return :delivered if delivered?
    return :expired if expired?(now)

    :pending
  end
end
