# == Schema Information
#
# Table name: buddy_ideas
#
#  id           :bigint           not null, primary key
#  body         :text             not null
#  category     :integer
#  remind_after :datetime
#  status       :integer          default("active"), not null
#  summary      :text
#  surfaced_at  :datetime
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
class BuddyIdea < ApplicationRecord
  belongs_to :user

  # A quick-captured thought, filed into a bucket. `category` is nil until it's
  # been sorted (an "anything" dump waiting on Buddy to categorize it).
  enum :category, { me: 0, home: 1, work: 2 }, prefix: :cat

  # active   → live, eligible to be surfaced.
  # deferred → "bring it up later" (see remind_after).
  # done     → acted on / resolved.
  # dropped  → the person told Buddy to forget it.
  enum :status, { active: 0, deferred: 1, done: 2, dropped: 3 }, prefix: :status

  validates :body, presence: true

  scope :live, -> { where(status: [:active, :deferred]) }

  # Ideas eligible to be surfaced right now: active, or a defer whose
  # remind_after has passed. Optionally scoped to a category.
  scope :surfaceable, ->(category=nil) {
    now = Time.current
    scope = where(status: [:active, :deferred]).where("remind_after IS NULL OR remind_after <= ?", now)
    category ? scope.where(category: category) : scope
  }

  CATEGORY_LABELS = { "me" => "Me", "home" => "Home", "work" => "Work" }.freeze

  def category_label
    CATEGORY_LABELS[category] || "Unsorted"
  end

  # How long this has been sitting, at the resolution that matters for
  # something measured in days rather than minutes. Buddy weighs it when
  # deciding which held item has the most claim on a lull.
  def waiting_label(now=Date.current)
    days = (now - created_at.to_date).to_i
    case days
    when ..0   then "today"
    when 1     then "since yesterday"
    when 2..13 then "#{days} days"
    else            "#{days / 7} weeks"
    end
  end
end
