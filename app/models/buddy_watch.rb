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
#  notify_user_id       :bigint
#  user_id              :bigint           not null
#
class BuddyWatch < ApplicationRecord
  include DistanceHelper

  belongs_to :user
  belongs_to :byte_conversation
  # When present, the watch delivers to this person's companion instead of the
  # owner's ("whenever I add to our Agenda, let Rocco know"). Same household.
  belongs_to :notify_user, class_name: "User", optional: true

  KINDS = %w[reminder prompt].freeze

  # The Jil trigger scopes a watch can listen on. Kept in lockstep with
  # Buddy::WatchMatcher::WATCHABLE_SCOPES - anything not here can't be
  # matched, so the tool must never store it.
  SCOPES = %w[travel chore_completion event deploy agenda_item].freeze

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

  # Same physical spot even after a rename: ~0.0015° ≈ 165m, forgiving enough
  # for a parking lot / large complex. `action` is also checked, so this only
  # ever compares arrivals-to-arrivals.
  PLACE_NEAR_THRESHOLD = 0.0015

  # True when EVERY key in `match` is satisfied by the trigger payload.
  # An empty `match` (e.g. deploy: "next deploy, no filter") matches any
  # payload for the scope. Scalar keys (action, chore_name, event name) are
  # compared exact-but-case-insensitive - the tool stores canonical names and
  # the payload carries the same, so equality is both sufficient and safe.
  # Substring matching is deliberately NOT used: it would make "uncompleted"
  # match a "completed" watch. The `place` key is special: a location is
  # matched by COORDINATE proximity (address identity) so a renamed place, or
  # a second contact at the same address, still matches - see #place_matches?.
  def matches?(payload)
    data = payload.respond_to?(:with_indifferent_access) ? payload.with_indifferent_access : {}
    (match || {}).all? { |key, want|
      next place_matches?(want, data) if key.to_s == "place"

      want = want.to_s.downcase.strip
      next true if want.blank?

      data[key].to_s.downcase.strip == want
    }
  end

  private

  # A place matches by coordinate proximity FIRST - two differently-named
  # contacts at the same address share coordinates and cross-match, and a
  # renamed place keeps matching. Falls back to name equality when either
  # side lacks real coordinates (e.g. a non-GPS travel trigger).
  def place_matches?(want, data)
    want     = want.respond_to?(:with_indifferent_access) ? want.with_indifferent_access : {}
    want_loc = Array(want[:loc]).map(&:to_f)
    here_loc = [data[:lat].to_f, data[:lng].to_f]
    both_have_coords = want_loc.length == 2 && want_loc.all?(&:nonzero?) && here_loc.all?(&:nonzero?)
    return true if both_have_coords && near?(here_loc, want_loc, PLACE_NEAR_THRESHOLD)

    want_name = want[:name].to_s.downcase.strip
    return false if want_name.blank?

    data[:location].to_s.downcase.strip == want_name
  end
end
