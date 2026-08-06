# == Schema Information
#
# Table name: buddy_idea_notes
#
#  id            :bigint           not null, primary key
#  buddy_idea_id :bigint           not null
#  body          :text             not null
#  source        :integer          default("person"), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
class BuddyIdeaNote < ApplicationRecord
  belongs_to :buddy_idea

  # Who put this here. A companion note is a summary of a conversation where the
  # thought got sharper; it's worth keeping and must never be read back as
  # though the person said it, which is the whole reason the column exists.
  enum :source, { person: 0, companion: 1 }, prefix: :from

  MAX_BODY = 2_000

  validates :body, presence: true, length: { maximum: MAX_BODY }

  scope :ordered, -> { order(created_at: :asc) }

  after_create :touch_thread

  # How long ago, at the resolution a thought is measured in. Same vocabulary as
  # BuddyIdea#waiting_label so a thread reads consistently whichever end you
  # look at it from.
  def age_label(now=Time.current)
    days = (now.to_date - created_at.to_date).to_i
    case days
    when ..0   then "today"
    when 1     then "yesterday"
    when 2..13 then "#{days}d ago"
    else            "#{days / 7}w ago"
    end
  end

  private

  def touch_thread
    buddy_idea.update_columns(last_touched_at: created_at, updated_at: Time.current)
  end
end
