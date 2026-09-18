# == Schema Information
#
# Table name: background_processes
#
#  id           :bigint           not null, primary key
#  current      :integer
#  detail       :string
#  finished_at  :datetime
#  heartbeat_at :datetime         not null
#  key          :string           not null
#  links        :jsonb            not null
#  name         :string           not null
#  source       :string
#  started_at   :datetime         not null
#  state        :integer          default("running"), not null
#  total        :integer
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
class BackgroundProcess < ApplicationRecord
  # The person whose hero shows it. Never another user's — the strip is a
  # window onto their own machinery.
  belongs_to :user

  # `waiting` is the one worth having: the Mac fills in an application until it
  # hits a question it cannot answer, and a chip that still reads "running"
  # there says the opposite of what is true. `failed` stays on screen instead
  # of vanishing, because a run that died is the thing most worth seeing.
  enum :state, { running: 0, waiting: 1, failed: 2, finished: 3 }, default: :running

  # Lowercase, no dots and no slashes: it travels in a URL path, and a dot
  # there is a format suffix. Colons are the convention for nesting
  # ("jobhunt:line", "mail:triage:51716") and are left alone by routing.
  KEY_RX = /\A[a-z0-9][a-z0-9_:-]{0,60}\z/

  # No heartbeat for this long and the chip says so rather than going on
  # claiming progress. Nothing is cleared automatically: a stuck process is
  # exactly what the person asked to be able to see, and clearing it is theirs.
  STALE_AFTER = 15.minutes

  # The FIRST link is where a tap goes. The rest are stored and reachable
  # through the API, but the chip is one line - it has room for a destination,
  # not for a row of them - so a caller that wants a link tapped puts it first.
  MAX_LINKS = 4

  # THE CHIP IS A CORNER OF A SCREEN, NOT A LINE IN A LOG.
  #
  # It sits over Buddy, and the whole point of him is that he is visible. So
  # the text is cut HERE rather than trusted to the callers or left to CSS: a
  # reporter three repos away writing "Left Fieldwire by Hilti filled but not
  # sent — 2 required fields came back empty" has no idea how wide the hero is,
  # and an ellipsis in the middle of a name that was never going to fit is a
  # worse answer than a name chosen to.
  #
  # The name is the WHOLE chip and gets 20. The detail is not drawn at all - it
  # is the chip's hover title, and the place a caller can say more without
  # spending a pixel on it.
  MAX_NAME = 20
  MAX_DETAIL = 32

  # Absolute http(s) or a path on this site, and nothing else. These arrive
  # from scripts and end up in `window.open`, so `javascript:` has to be
  # impossible rather than unlikely.
  LINK_RX = %r{\A(?:https?://|/)}i

  # Work that CLAIMS to be moving drops off the strip eventually. A laptop that
  # slept through the night leaves a chip that will never be updated again, and
  # a day later it is not news. The row stays for history.
  #
  # `waiting` and `failed` are exempt, and that is not an oversight. Both are
  # states a caller deliberately put the chip into, neither will ever heartbeat
  # again, and both are waiting on a PERSON - so ageing one out would silently
  # throw away the thing he was meant to come back to. They go when he clears
  # them, or when the work reports itself alive again.
  FORGET_AFTER = 24.hours

  PARKED = %i[waiting failed].freeze

  # The only attributes a report may set. Everything else on the row - who it
  # belongs to, when it started, when it was last heard from - is the server's.
  WRITABLE = %i[name state detail current total links source].freeze

  validates :key, presence: true, format: { with: KEY_RX }
  validates :name, presence: true

  # Accepts what a caller would naturally write: a bare url, a list of them, or
  # a list of {label:, url:}. An entry with no usable url is DROPPED rather
  # than stored as a pill that goes nowhere when it is tapped.
  def links=(value)
    super(self.class.normalize_links(value))
  end

  def name=(value)
    super(value.to_s.strip.truncate(MAX_NAME))
  end

  def detail=(value)
    super(value.presence && value.to_s.strip.truncate(MAX_DETAIL))
  end

  def self.normalize_links(value)
    Array.wrap(value).filter_map { |entry|
      entry = { url: entry } if entry.is_a?(String)
      entry = entry.respond_to?(:to_h) ? entry.to_h.symbolize_keys : {}
      url = entry[:url].to_s.strip
      next unless url.match?(LINK_RX)

      { "label" => link_label(entry[:label], url), "url" => url }
    }.uniq { |link| link["url"] }.first(MAX_LINKS)
  end

  # An unlabelled link is labelled by where it goes, which beats a row of
  # pills all reading "Open".
  def self.link_label(given, url)
    label = given.to_s.strip
    return label.truncate(24) if label.present?

    host = begin
      URI.parse(url).host
    rescue URI::InvalidURIError
      nil
    end
    host.present? ? host.delete_prefix("www.") : url.split("?").first.truncate(24)
  end

  scope :live, -> { where(finished_at: nil) }
  scope :recent, -> { where(state: PARKED).or(where(heartbeat_at: FORGET_AFTER.ago..)) }

  # What the hero shows: still going, and heard from this side of yesterday.
  # Oldest first, so a long-running process keeps its place in the stack while
  # short ones come and go beneath it.
  def self.live_for(user)
    where(user: user).live.recent.order(:started_at, :id)
  end

  def self.live_find(user, key)
    where(user: user, key: key.to_s).live.order(:id).last
  end

  # The upsert behind every write endpoint. Only the attributes actually named
  # are applied: a caller reporting `current` alone must not blank the name it
  # set when it started, and one reporting a step must not reset the count.
  #
  # `heartbeat_at` moves on every report even when nothing else changed, which
  # is the difference between a process that is quiet and one that is stuck.
  def self.report!(user:, key:, **attrs)
    process = live_find(user, key)
    attrs = attrs.compact
    # `url:` is the one-link shorthand, and the thing a caller with one link
    # writes without being told to. An explicit `links:` wins.
    single = attrs.delete(:url)
    attrs[:links] = single if single.present? && attrs[:links].blank?
    if process.nil?
      process = new(user: user, key: key.to_s, name: attrs[:name].presence || key.to_s)
      process.started_at = Time.current
    end

    process.assign_attributes(attrs.slice(*WRITABLE))
    process.heartbeat_at = Time.current

    # A caller that says it has finished HAS finished, whichever route it said
    # it on. Without this the row would sit in the live list wearing a state
    # nothing renders, and the strip and the database would disagree about
    # whether the work was still going.
    if process.finished?
      process.finished_at ||= Time.current
      process.save!
      process.broadcast(reason: :cleared)
      return process
    end

    process.save!
    process.broadcast(reason: :reported)
    process
  end

  # Clearing is idempotent and says which branch it took, so a script that
  # cannot tell a timeout from a success can call it twice and a person
  # watching the log can tell the difference.
  def self.clear!(user:, key:)
    process = live_find(user, key)
    return nil if process.nil?

    process.finish!
    process
  end

  # What in-Rails callers use. A chip is a nicety; it must never be the reason
  # a worker fails, and a worker that reports its own progress would otherwise
  # gain a new way to die that the work itself never had.
  #
  # The bang versions stay strict, because the endpoint's caller is a script
  # that wants to be told its report was rejected.
  def self.note(user:, key:, **attrs)
    report!(user: user, key: key, **attrs)
  rescue StandardError => e
    Rails.logger.warn("[BackgroundProcess] #{key} report failed: #{e.class}: #{e.message}")
    nil
  end

  def self.clear(user:, key:)
    clear!(user: user, key: key)
  rescue StandardError => e
    Rails.logger.warn("[BackgroundProcess] #{key} clear failed: #{e.class}: #{e.message}")
    nil
  end

  def finish!
    update!(state: :finished, finished_at: Time.current, heartbeat_at: Time.current)
    broadcast(reason: :cleared)
  end

  # Nothing heard for a while. Only ever asked of work that claims to be
  # moving — `waiting` is stalled on purpose and `failed` has already said so.
  def stale?
    running? && heartbeat_at.present? && heartbeat_at < STALE_AFTER.ago
  end

  def serialize
    {
      id:           id,
      key:          key,
      name:         name,
      state:        state,
      detail:       detail,
      current:      current,
      total:        total,
      links:        links,
      source:       source,
      stale:        stale?,
      started_at:   started_at&.iso8601(3),
      heartbeat_at: heartbeat_at&.iso8601(3),
      finished_at:  finished_at&.iso8601(3),
    }
  end

  # Same shape as the timer chips next to it: one envelope per change, and the
  # strip reconciles rather than refetching.
  def broadcast(reason:)
    MonitorChannel.broadcast_to(user, {
      id:        :background,
      channel:   :background,
      timestamp: Time.current.to_i,
      data:      {
        reason:     reason,
        process_id: id,
        process:    serialize,
      },
    })
  end
end
