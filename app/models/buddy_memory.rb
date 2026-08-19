# == Schema Information
#
# Table name: buddy_memories
#
#  id                :bigint           not null, primary key
#  category          :integer
#  check_in_at       :datetime
#  checked_in_at     :datetime
#  content           :text             not null
#  expires_at        :datetime
#  kind              :integer          default("concept"), not null
#  last_touched_at   :datetime
#  last_used_at      :datetime
#  metadata          :jsonb            not null
#  priority          :integer          default(0), not null
#  relevant_at       :datetime
#  severity          :integer          default(0), not null
#  status            :integer          default("active"), not null
#  summary           :text
#  surfaced_at       :datetime
#  tags              :jsonb            not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  source_message_id :bigint
#  user_id           :bigint           not null

#
# Everything Buddy holds about a person, in one table.
#
# This was two: `buddy_memories` (durable facts) and `buddy_ideas` (thoughts
# handed over to hold). They were the same record wearing different names — both
# are something kept about a person, retrieved later, and eventually resolved or
# forgotten — and keeping them apart meant two search paths, two recall rules,
# and no way for "we forgot the sleeping bags" to be both a fact worth keeping
# and a thing to bring up next time camping comes round.
#
# `kind` is what sort of record it is, `tags` is how it gets found, `category`
# is which pile a stashed thought was filed into. Three fields, three jobs.
class BuddyMemory < ApplicationRecord
  belongs_to :user
  belongs_to :source_message, class_name: "ByteMessage", optional: true

  # The thread. Optional by design — a `concept` never grows one, a `followup`
  # collects one every time the person gives an update.
  has_many :notes, -> { ordered },
    class_name: "BuddyMemoryNote", inverse_of: :buddy_memory, dependent: :destroy

  # concept    → a durable fact about them or their world ("log means chore").
  # preference → how they want things done. The ONLY kind that ships inline in
  #              every prompt; see Buddy::Personality#memories_block.
  # stash      → a thought they handed over to hold. Has a pile and a category.
  # followup   → something worth coming back to ask about. Carries check_in_at.
  enum :kind, { concept: 0, preference: 1, stash: 2, followup: 3 }, prefix: :kind

  # active   → live.
  # deferred → pushed out (see remind_after's successor, relevant_at).
  # done     → resolved.
  # dropped  → told to forget it.
  enum :status, { active: 0, deferred: 1, done: 2, dropped: 3 }, prefix: :status

  # Carried over from buddy_ideas. nil until a dumped thought has been sorted.
  enum :category, { me: 0, home: 1, work: 2 }, prefix: :cat

  MAX_CONTENT = 500
  MAX_SUMMARY = 200

  # How important this is, on a scale rather than in buckets. 0 means keep it
  # but never raise it; 100 means it is the biggest thing in their life and will
  # be for a while. The middle is where nearly everything lives, which is
  # exactly why a four-value enum couldn't carry it.
  SEVERITY_RANGE = (0..100)

  # Below this, a record is never a candidate for an unprompted check-in. It can
  # still be recalled, searched and used — it just isn't worth interrupting for.
  CHECK_IN_FLOOR = 25

  validates :content, presence: true, length: { maximum: MAX_CONTENT }
  validates :summary, length: { maximum: MAX_SUMMARY }, allow_nil: true
  validates :severity, inclusion: { in: SEVERITY_RANGE }

  scope :recent, -> { order(created_at: :desc) }

  # Not expired. Durable records have a null expires_at and are always active.
  scope :unexpired, ->(now=Time.current) { where("expires_at IS NULL OR expires_at > ?", now) }

  # Kept for the handful of callers that predate the merge.
  scope :active, ->(now=Time.current) { unexpired(now) }

  scope :live, -> { where(status: [:active, :deferred]) }

  # Live AND actually due to be seen. A deferred thought and a follow-up waiting
  # on next week's surgery are the same state, so one field answers both:
  # `relevant_at` in the future means hold it back without closing it.
  scope :surfaceable, ->(now=Time.current) {
    live.where("relevant_at IS NULL OR relevant_at <= ?", now)
  }

  # The set that ships inline in EVERY prompt. Deliberately only preferences:
  # how someone wants things done is useless if it has to be looked up, because
  # the moment it applies is the moment nobody thought to look.
  #
  # Everything else is reached by tag through search_memories. That replaced a
  # flat `limit(30)` on all memories ordered by reinforcement count, which
  # silently dropped the tail — and dropped it worst for a fact mentioned once
  # and never repeated, which is precisely the kind most worth having kept.
  scope :always_loaded, -> { unexpired.kind_preference.order(Arel.sql("priority DESC, created_at DESC")) }

  # Ordered for recall: severity first (what matters most), then reinforcement,
  # then recency.
  scope :for_recall, -> { unexpired.order(Arel.sql("severity DESC, priority DESC, created_at DESC")) }

  # Records with a check-in armed and due. `relevant_at` gates whether it is
  # live yet at all — a parent's surgery next week is severe now and worth
  # nothing until the week turns.
  scope :check_in_due, ->(now=Time.current) {
    live.where(kind: kinds[:followup])
      .where.not(check_in_at: nil)
      .where(check_in_at: ..now)
      .where("relevant_at IS NULL OR relevant_at <= ?", now)
  }

  # Everything with a check-in still ahead of it, for the re-planner.
  scope :check_in_pending, ->(now=Time.current) {
    live.where(kind: kinds[:followup]).where("check_in_at > ?", now)
  }

  PRIORITY_CAP = 100

  # Re-mention of something we already hold: stamp it fresh and nudge priority
  # rather than storing a duplicate. Reinforced records stay near the top; ones
  # that go cold sink so they can be curated later.
  def reinforce!
    update_columns(
      last_used_at: Time.current,
      priority:     [priority + 1, PRIORITY_CAP].min,
      updated_at:   Time.current,
    )
  end

  CATEGORY_LABELS = { "me" => "Me", "home" => "Home", "work" => "Work" }.freeze

  def category_label
    CATEGORY_LABELS[category] || "Unsorted"
  end

  # Tags as a plain array of strings, however the column got written. jsonb will
  # happily hold a hash or a string, and a nil-safe reader here is cheaper than
  # every caller guarding.
  def tag_list
    case tags
    when Array then tags.map { |t| t.to_s.downcase.strip }.reject(&:empty?)
    when String then tags.split(",").map { |t| t.strip.downcase }.reject(&:empty?)
    else []
    end
  end

  def tag_list=(values)
    self.tags = Array(values).map { |t| t.to_s.downcase.strip }.reject(&:empty?).uniq
  end

  # Does this record answer to `term`? Tags first, then the category, so a
  # single search path covers both without the caller knowing which one holds
  # the word.
  def tagged?(term)
    needle = term.to_s.downcase.strip
    return false if needle.empty?

    tag_list.include?(needle) || category.to_s == needle
  end

  # Worth PLANNING a check-in for: a live follow-up that clears the severity
  # floor. Deliberately says nothing about `relevant_at` — next week's surgery
  # very much needs a slot, it just needs one on the far side of the surgery.
  def check_in_plannable?
    kind_followup? && (status_active? || status_deferred?) && severity >= CHECK_IN_FLOOR
  end

  # Worth ASKING about right now. Everything above, plus a `relevant_at` that
  # has actually arrived. Splitting the two is what stops a re-plan either
  # forgetting a dated follow-up or firing it early.
  def check_in_candidate?(now=Time.current)
    check_in_plannable? && (relevant_at.blank? || relevant_at <= now)
  end

  # ---- thread helpers, carried over from BuddyIdea ----

  # How long this has been sitting, at the resolution that matters for something
  # measured in days rather than minutes.
  def waiting_label(now=Date.current)
    days = (now - created_at.to_date).to_i
    case days
    when ..0   then "today"
    when 1     then "since yesterday"
    when 2..13 then "#{days} days"
    else            "#{days / 7} weeks"
    end
  end

  # A thread is one somebody came back to. One-note-and-done is the common case
  # and reads as an ordinary held item; the ones worth treating differently are
  # the ones that grew.
  def thread?
    notes.loaded? ? notes.any? : notes.exists?
  end

  def touched_at
    last_touched_at || created_at
  end

  # "3 notes, last week" — how much is in here and how warm it still is. Nil for
  # a record nobody has added to.
  def thread_label(now=Time.current)
    count = notes.loaded? ? notes.size : notes.count
    return nil if count.zero?

    ["#{count} #{"note".pluralize(count)}", "last #{touched_ago(now)}"].join(", ")
  end

  # The seed plus everything added to it, oldest first, as one readable block.
  def transcript(now=Time.current)
    lines = ["[seed, #{waiting_label(now.to_date)}] #{content.to_s.strip}"]
    notes.each { |n| lines << "[#{"you, " if n.from_companion?}#{n.age_label(now)}] #{n.body.to_s.strip}" }
    lines.join("\n")
  end

  # What a search result or an admin row calls this.
  def label
    summary.presence || content.to_s.truncate(120)
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
