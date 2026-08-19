# == Schema Information
#
# Table name: buddy_ideas
#
#  id              :bigint           not null, primary key
#  user_id         :bigint           not null
#  category        :integer
#  body            :text             not null
#  summary         :text
#  status          :integer          default("active"), not null
#  surfaced_at     :datetime
#  remind_after    :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  last_touched_at :datetime
#
# LEGACY — merged into BuddyMemory (`kind: :stash`).
#
# Nothing in the app reads this any more. It stays reachable solely so
# lib/scripts/merge_buddy_ideas_into_memories.rb can copy the rows across in
# production; once that has run and been verified, this model, BuddyIdeaNote,
# and both tables go.
class BuddyIdea < ApplicationRecord
  belongs_to :user

  # Everything added to this thought after the seed. Ordered oldest-first,
  # because reading a thread backwards is reading it wrong.
  has_many :notes, -> { ordered }, class_name: "BuddyIdeaNote", dependent: :destroy

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

  # A thread is an idea somebody came back to. One-note-and-done is the common
  # case and reads as an ordinary held item; the ones worth treating differently
  # are the ones that grew.
  def thread?
    notes.loaded? ? notes.any? : notes.exists?
  end

  def touched_at
    last_touched_at || created_at
  end

  # "3 notes, last week" — how much is in here and how warm it still is. Nil for
  # an idea nobody has added to, so an untouched pile reads exactly as it did
  # before any of this existed.
  def thread_label(now = Time.current)
    count = notes.loaded? ? notes.size : notes.count
    return nil if count.zero?

    ["#{count} #{'note'.pluralize(count)}", "last #{touched_ago(now)}"].join(", ")
  end

  # The seed plus everything added to it, oldest first, as one readable block.
  # This is what "remind me what this was" hands back.
  def transcript(now = Time.current)
    lines = ["[seed, #{waiting_label(now.to_date)}] #{body.to_s.strip}"]
    notes.each { |n| lines << "[#{n.from_companion? ? 'you, ' : ''}#{n.age_label(now)}] #{n.body.to_s.strip}" }
    lines.join("\n")
  end

  private

  def touched_ago(now)
    days = (now.to_date - touched_at.to_date).to_i
    case days
    when ..0   then "today"
    when 1     then "yesterday"
    when 2..6  then "#{days}d ago"
    when 7..13 then "week"
    else            "#{days / 7}w ago"
    end
  end
end
