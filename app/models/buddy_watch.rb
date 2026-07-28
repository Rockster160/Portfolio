# == Schema Information
#
# Table name: buddy_watches
#
#  id                   :bigint           not null, primary key
#  body                 :text             not null
#  cancelled_at         :datetime
#  expires_at           :datetime
#  fired_at             :datetime
#  kind                 :string           default("prompt"), not null
#  last_fired_at        :datetime
#  match                :jsonb            not null
#  metadata             :jsonb            not null
#  one_shot             :boolean          default(TRUE), not null
#  trigger_scope        :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint           not null
#  user_id              :bigint           not null
#
class BuddyWatch < ApplicationRecord
  belongs_to :user
  belongs_to :byte_conversation

  KINDS = %w[reminder prompt].freeze

  # The Jil trigger scopes a watch can listen on. Kept in lockstep with
  # Buddy::WatchMatcher::WATCHABLE_SCOPES - anything not here can't be
  # matched, so the tool must never store it.
  SCOPES = %w[travel chore_completion event deploy].freeze

  # `active` = not terminally fired, not cancelled, not expired. One-shot
  # watches set `fired_at` after firing (terminal); repeating watches only
  # set `last_fired_at` and stay active until cancelled/expired.
  scope :active, ->(now = Time.current) {
    where(fired_at: nil, cancelled_at: nil)
      .where("expires_at IS NULL OR expires_at > ?", now)
  }

  validates :body,          presence: true, length: { maximum: 500 }
  validates :kind,          inclusion: { in: KINDS }
  validates :trigger_scope, inclusion: { in: SCOPES }

  # True when EVERY key in `match` is satisfied by the trigger payload.
  # An empty `match` (e.g. deploy: "next deploy, no filter") matches any
  # payload for the scope. Comparison is exact but case-insensitive - the
  # tool stores canonical names (resolved chore/place names, the exact
  # action word), and the payload carries the same, so equality is both
  # sufficient and safe. Substring matching is deliberately NOT used: it
  # would make "uncompleted" match a "completed" watch.
  def matches?(payload)
    data = payload.respond_to?(:with_indifferent_access) ? payload.with_indifferent_access : {}
    (match || {}).all? { |key, want|
      want = want.to_s.downcase.strip
      next true if want.blank?

      data[key].to_s.downcase.strip == want
    }
  end
end
