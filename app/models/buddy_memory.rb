# == Schema Information
#
# Table name: buddy_memories
#
#  id           :bigint           not null, primary key
#  content      :text             not null
#  expires_at   :datetime
#  last_used_at :datetime
#  metadata     :jsonb            not null
#  priority     :integer          default(0), not null
#  tags         :jsonb            not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
class BuddyMemory < ApplicationRecord
  belongs_to :user

  scope :recent, -> { order(created_at: :desc) }

  # Not expired (durable facts have a null expires_at and are always active).
  scope :active, ->(now = Time.current) { where("expires_at IS NULL OR expires_at > ?", now) }

  # The set injected into the prompt: active only, and ordered so important +
  # reinforced facts win the cap. `priority` rises via #reinforce!, so a fact
  # the person keeps bringing up floats to the top and never falls out; ties
  # break on recency.
  scope :for_recall, -> { active.order(Arel.sql("priority DESC, created_at DESC")) }

  validates :content, presence: true, length: { maximum: 500 }

  # Re-mention of a fact we already hold: stamp it fresh and nudge its priority
  # up (capped) rather than storing a duplicate. This is our "still relevant"
  # signal - reinforced facts stay near the top; ones that go cold sink so they
  # can be surfaced for curation later.
  PRIORITY_CAP = 100

  def reinforce!
    update_columns(
      last_used_at: Time.current,
      priority:     [priority + 1, PRIORITY_CAP].min,
      updated_at:   Time.current,
    )
  end
end
