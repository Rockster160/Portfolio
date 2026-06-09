# == Schema Information
#
# Table name: timers
#
#  id                  :bigint           not null, primary key
#  archived_at         :datetime
#  callbacks           :jsonb            not null
#  color               :text
#  confirmed_at        :datetime
#  dial_config         :jsonb            not null
#  dial_step_index     :integer          default(0), not null
#  disabled            :boolean          default(FALSE), not null
#  duration_ms         :bigint
#  end_at              :datetime
#  fire_jid            :string
#  fire_scheduled_for  :datetime
#  fired_at            :datetime
#  height              :integer          default(0), not null
#  kind                :integer          default("countdown"), not null
#  max_value           :integer
#  min_value           :integer
#  name                :text             default(""), not null
#  paused_at           :datetime
#  paused_remaining_ms :bigint
#  pos_x               :integer          default(0), not null
#  pos_y               :integer          default(0), not null
#  repeat              :boolean          default(FALSE), not null
#  repeat_count        :integer          default(0), not null
#  require_confirm_tap :boolean          default(FALSE), not null
#  reset_value         :integer          default(0), not null
#  started_at          :datetime
#  step                :integer          default(1), not null
#  value               :integer          default(0), not null
#  width               :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  section_id          :integer
#  timer_page_id       :bigint
#  user_id             :bigint           not null
#
class Timer < ApplicationRecord
  KINDS = { countdown: 0, counter: 1, dial: 2 }.freeze
  enum :kind, KINDS

  belongs_to :user
  belongs_to :timer_page, optional: true
  has_many :share_tokens, class_name: "TimerShareToken", dependent: :destroy

  scope :live,    -> { where(archived_at: nil) }
  scope :running, -> { live.where.not(started_at: nil).where(paused_at: nil) }
  scope :ordered, -> { order(:pos_y, :pos_x, :id) }

  validates :duration_ms, presence: true, numericality: { greater_than: 0 }, if: :countdown?
  validate  :min_le_max_when_set, if: :counter?

  # =========================
  # Countdown lifecycle
  # =========================

  def start!(at: Time.current, preserve_repeat_count: false)
    return unless countdown?

    transaction do
      duration_secs = duration_ms / 1000.0
      attrs = {
        started_at:          at,
        paused_at:           nil,
        paused_remaining_ms: nil,
        end_at:              at + duration_secs.seconds,
        fired_at:            nil,
        confirmed_at:        nil,
      }
      attrs[:repeat_count] = 0 unless preserve_repeat_count
      assign_attributes(attrs)
      save!
      reschedule_fire!
      reschedule_countdown_callbacks!
    end
  end

  def pause!
    return unless countdown? && running?

    transaction do
      remaining = [((end_at - Time.current) * 1000).to_i, 0].max
      assign_attributes(
        paused_at:           Time.current,
        paused_remaining_ms: remaining,
        started_at:          nil,
        end_at:              nil,
      )
      save!
      cancel_fire!
      cancel_countdown_callbacks!
    end
  end

  def resume!
    return unless countdown? && paused?

    transaction do
      now = Time.current
      assign_attributes(
        started_at:          now,
        paused_at:           nil,
        end_at:              now + (paused_remaining_ms / 1000.0).seconds,
        paused_remaining_ms: nil,
      )
      save!
      reschedule_fire!
      reschedule_countdown_callbacks!
    end
  end

  def reset!
    transaction do
      cancel_fire!
      cancel_countdown_callbacks!
      case kind.to_sym
      when :countdown
        update!(
          started_at: nil, paused_at: nil, paused_remaining_ms: nil,
          end_at: nil, fired_at: nil, confirmed_at: nil, repeat_count: 0
        )
      when :counter
        update!(value: reset_value)
      when :dial
        update!(dial_step_index: 0)
      end
    end
  end

  def running?
    countdown? && started_at.present? && paused_at.nil?
  end

  def paused?
    countdown? && paused_at.present?
  end

  def fired?
    fired_at.present?
  end

  # Server-authoritative current remaining (ms) — clients trust this on reconcile.
  def remaining_ms
    return nil unless countdown?
    return paused_remaining_ms if paused?
    return duration_ms unless running?

    [((end_at - Time.current) * 1000).to_i, 0].max
  end

  # =========================
  # Counter / Dial
  # =========================

  def apply_increment!(by:)
    return unless counter?

    # Min/max are display-bounded only — the value is free to go past
    # either bound and the ring just clamps visually on the client.
    direction = by.to_i
    new_value = value + (direction * step)
    update!(value: new_value)
    # :counter_change fires on every step. Match-clauses on the callback
    # (value + optional direction) decide whether anything dispatches.
    fire_callbacks!(event: :counter_change, context: { value: new_value, direction: direction })
    maybe_fire_counter_event!(direction: direction)
  end

  def advance_dial!(by: 1)
    return unless dial?

    total = dial_step_count
    return if total.zero?

    new_index = (dial_step_index + by.to_i) % total
    crossed_zero = new_index < dial_step_index && by.to_i.positive?
    update!(dial_step_index: new_index)

    # :dial_step fires for EVERY advance; :complete only on revolution wrap.
    # The context hash carries the current section/sub name so callback
    # `when` clauses with `section`/`sub` filters can narrow the match.
    step = current_dial_step
    fire_callbacks!(event: :dial_step, context: step) if step
    fire_callbacks!(event: :complete, context: step) if crossed_zero
  end

  # Move a dial to the first step that belongs to the section whose name
  # matches `name` (case-insensitive). Used by chain `op: goto` so one
  # dial can park another at a named position rather than counting
  # increments. No-op if the section isn't found — keeps misconfigured
  # callbacks silent rather than blowing up the trigger that fired them.
  def goto_dial_section!(name)
    return unless dial?

    target = String(name).strip
    return if target.empty?

    cfg = (dial_config || {}).deep_symbolize_keys
    sections = Array(cfg[:sections])
    idx = 0
    sections.each_with_index do |sec, i|
      if sec[:name].to_s.casecmp?(target)
        update!(dial_step_index: idx)
        # Mirror advance_dial!'s contract — landing on a step should let
        # that step's own :dial_step callbacks fire (e.g. cascading dials).
        fire_callbacks!(event: :dial_step, context: current_dial_step)
        return
      end
      idx += Array(sec[:subs]).any? ? sec[:subs].length : 1
    end
  end

  # Resolves the dial's current position to { section_name:, sub_name: }.
  # Used as match-context for fire_callbacks! and as the goto landing.
  def current_dial_step
    return nil unless dial?

    cfg = (dial_config || {}).deep_symbolize_keys
    sections = Array(cfg[:sections])
    return nil if sections.empty?

    cursor = 0
    sections.each do |sec|
      subs = Array(sec[:subs])
      span = subs.any? ? subs.length : 1
      if dial_step_index < cursor + span
        return {
          section_name: sec[:name].to_s,
          sub_name:     subs.any? ? subs[dial_step_index - cursor].to_s : nil,
        }
      end
      cursor += span
    end
    nil
  end

  # =========================
  # Sidekiq scheduling
  # =========================

  def reschedule_fire!
    cancel_fire!
    return unless countdown? && end_at

    new_jid = TimerFireWorker.perform_at(end_at, id)
    update_columns(fire_jid: new_jid, fire_scheduled_for: end_at)
  end

  def cancel_fire!
    current_jid = fire_jid
    return if current_jid.blank?

    job = ::Sidekiq::ScheduledSet.new.find { |j| j.jid == current_jid && j.klass == "TimerFireWorker" }
    job&.delete
    update_columns(fire_jid: nil, fire_scheduled_for: nil)
  rescue StandardError => e
    Rails.logger.warn("Timer##{id} cancel_fire! failed: #{e.message}")
  end

  # Schedule a Sidekiq job for each non-sound `countdown_at` callback so
  # mid-countdown push/jil/chain triggers fire even if no client is open
  # at that moment. Sound thens are skipped — the page ticker plays
  # those locally for tight latency (and a closed page has no speaker).
  def reschedule_countdown_callbacks!
    cancel_countdown_callbacks!
    return unless countdown? && end_at

    Array(callbacks).each do |raw|
      cb = normalize_callback(raw)
      next unless cb && cb.dig(:when, :type).to_s == "countdown_at"
      next if cb.dig(:then, :type).to_s == "sound"

      remaining_ms = cb.dig(:when, :remaining_ms).to_i
      next unless remaining_ms.positive?

      fire_at = end_at - (remaining_ms / 1000.0).seconds
      next if fire_at <= Time.current

      TimerCallbackWorker.perform_at(fire_at, id, cb[:id].to_s)
    end
  end

  # Sweeps the Sidekiq ScheduledSet for any TimerCallbackWorker jobs
  # tied to this timer and deletes them. Matches `cancel_fire!`'s
  # pattern; we don't track jids separately because callbacks change
  # often and a sweep is correct under any edit/pause sequence.
  def cancel_countdown_callbacks!
    ::Sidekiq::ScheduledSet.new.each do |job|
      next unless job.klass == "TimerCallbackWorker"
      next unless Array(job.args).first == id

      job.delete
    end
  rescue StandardError => e
    Rails.logger.warn("Timer##{id} cancel_countdown_callbacks! failed: #{e.message}")
  end

  # =========================
  # Fire + callbacks
  # =========================

  def fire_and_maybe_repeat!
    # Clear the fire bookkeeping immediately so the row reflects "job
    # has run, nothing scheduled" — without this, fire_jid would keep
    # pointing at a long-gone Sidekiq job, making it ambiguous whether
    # the timer is still waiting to fire.
    update_columns(
      fired_at:           Time.current,
      fire_jid:           nil,
      fire_scheduled_for: nil,
    )
    fire_callbacks!(event: :complete)
    # Pick up anything a chain mutated on this same row via a separate
    # AR instance (e.g. a `then: { chain, op: enable }` pointing at the
    # firing timer itself). Without the reload the trailing broadcast
    # would ship pre-chain state.
    reload

    # The CLIENT drives the restart of repeating timers — it detects the
    # fire (either locally when remaining hits zero, or via this :fired
    # broadcast) and immediately POSTs /start, which is idempotent and
    # robust regardless of whether Sidekiq is running. Doing the restart
    # server-side here led to: (a) the client sitting in a fired state
    # while waiting for a broadcast that never arrived if Sidekiq was
    # down; (b) a race between worker-restart and client-restart causing
    # double-starts. Callbacks have already fired above; the client
    # restart is purely a lifecycle reset.
    broadcast(reason: :fired)
  end

  # Confirm = the user acknowledged the fired state. Fires the :confirm
  # callbacks once, then RETURNS THE TIMER TO ITS NEUTRAL STARTING
  # STATE so the card visual drops out of the red/pulsing "needs
  # attention" treatment. Without this clear, the renderer's
  # `fired = fired_at && !confirmed_at` check stays false but
  # `started_at` was still populated, leaving the card stuck showing
  # "tap to pause" against an expired end_at.
  def confirm!
    return if confirmed_at.present? && started_at.nil?

    fire_callbacks!(event: :confirm)
    update!(
      confirmed_at:        Time.current,
      fired_at:            nil,
      started_at:          nil,
      end_at:              nil,
      paused_at:           nil,
      paused_remaining_ms: nil,
      repeat_count:        0,
    )
    broadcast(reason: :confirmed)
  end

  # =========================
  # Callback model: each callback is one (when, then) pair.
  #
  #   { id:, when: { type:, ...args }, then: { type:, ...args } }
  #
  # `fire_callbacks!(event:, context:)` is the dispatcher: it walks every
  # callback, evaluates whether its `when` clause matches the current
  # event+context, and if so invokes `dispatch_then(then_clause)`. This
  # keeps the trigger side (when something happens) decoupled from the
  # action side (what to do), so any pairing is expressible.
  #
  # Legacy callbacks (`event:`, `type:` at top level, flat fields) are
  # adapted on read by `normalize_callback` — no DB migration needed.
  # The dev conversion script `lib/scripts/convert_timer_callbacks.rb`
  # rewrites them in place so the editor always sees the new shape.
  # =========================

  def fire_callbacks!(event:, context: nil)
    ctx = context || {}
    Array(callbacks).each do |raw|
      cb = normalize_callback(raw)
      next unless cb
      next unless when_matches?(cb[:when], event, ctx)

      dispatch_then(cb[:then])
    end
  end

  # Worker-entry. Used by TimerCallbackWorker to fire ONE specific
  # callback (looked up by id) when a scheduled mid-countdown trigger
  # comes due. Sound thens are skipped server-side — the client's
  # ticker handles those for tight latency.
  def fire_callback_by_id!(callback_id)
    raw = Array(callbacks).find { |c| (c.is_a?(Hash) ? c["id"] || c[:id] : nil).to_s == callback_id.to_s }
    return unless raw

    cb = normalize_callback(raw)
    return unless cb
    return if cb.dig(:then, :type).to_s == "sound"

    dispatch_then(cb[:then])
  end

  # Converts ANY callback shape (new or legacy) to:
  #   { id:, when: { type:, ...args }, then: { type:, ...args } }
  # Returns nil if the callback can't be interpreted at all.
  def normalize_callback(raw)
    cb = raw.deep_symbolize_keys
    return cb.slice(:id, :when, :then) if cb[:when].is_a?(Hash) && cb[:then].is_a?(Hash)

    event = cb[:event].to_s
    type  = cb[:type].to_s

    when_clause =
      case event
      when "step"
        { type: "dial_step", section: cb[:match_section].to_s, sub: cb[:match_sub].to_s }
      when "confirm"
        { type: "confirm" }
      else
        { type: "complete" }
      end

    then_clause =
      case type
      when "push"
        { type: "push", title: cb[:title].to_s, body: cb[:body].to_s }
      when "sound"
        { type: "sound", chime: cb[:chime].to_s.presence || "soft", cadence: cb[:cadence].to_s.presence || "once" }
      when "jil"
        { type: "jil", trigger: cb[:trigger].to_s }
      when "chain"
        chain = { type: "chain", target_timer_id: cb[:target_timer_id], op: cb[:op].to_s.presence || "start" }
        chain[:by]      = cb[:by] if cb[:by].present?
        chain[:section] = cb[:goto_section].to_s if cb[:goto_section].present?
        chain
      else
        return nil
      end

    { id: cb[:id], when: when_clause, then: then_clause }
  end

  def when_matches?(when_clause, event, context)
    w = (when_clause || {}).deep_symbolize_keys

    case w[:type].to_s
    when "complete"
      event.to_s == "complete"
    when "confirm"
      event.to_s == "confirm"
    when "dial_step"
      return false unless event.to_s == "dial_step"

      section = w[:section].to_s.strip
      sub     = w[:sub].to_s.strip
      return false if section.present? && !context[:section_name].to_s.casecmp?(section)
      return false if sub.present?     && !context[:sub_name].to_s.casecmp?(sub)

      true
    when "counter_reaches"
      return false unless event.to_s == "counter_change"

      target_value = w[:value]
      return false if target_value.nil?
      return false unless context[:value].to_i == target_value.to_i

      case w[:direction].to_s
      when "increasing" then context[:direction].to_i.positive?
      when "decreasing" then context[:direction].to_i.negative?
      else                   true
      end
    when "countdown_at"
      # Scheduled separately; the worker fires this callback directly
      # via fire_callback_by_id! rather than going through the generic
      # event bus, so when_matches? never gets called for it.
      false
    else
      false
    end
  end

  def dispatch_then(then_clause)
    t = (then_clause || {}).deep_symbolize_keys

    case t[:type].to_s
    when "push"
      WebPushNotifications.send_to(
        user,
        {
          title: t[:title].to_s.presence || name.presence || "Timer",
          body:  t[:body].to_s.presence  || "Time's up",
          tag:   "timer-#{id}",
          icon:  "/assets/favicon/android-chrome-192x192.png",
          data:  { url: notification_url, timer_id: id },
        },
        channel: :timers,
      )
    when "sound"
      # Client-only. The page's ticker / fire detection plays the chime
      # locally; server never produces audio.
      nil
    when "jil"
      scope = t[:trigger].to_s
      return if scope.blank?

      ::Jil.trigger(user, scope.to_sym, { timer_id: id, name: name }, auth: :trigger)
    when "chain"
      # Chains accept either `target_timer_id` (most precise) OR
      # `target_timer_name` (case-insensitive name match). The name
      # variant lets task authors write callbacks before the target
      # exists — e.g. a setup script that creates "Swarm" later — and
      # also survives recreate cycles where the row id changes but
      # the name stays put. Id wins when both are present.
      target =
        if t[:target_timer_id].present?
          user.timers.find_by(id: t[:target_timer_id])
        elsif t[:target_timer_name].present?
          user.timers.where("timers.name ILIKE ?", t[:target_timer_name].to_s).first
        end
      return unless target

      # When the chain points at THIS row, route through `self`. Without
      # this, the chain mutates a separate AR instance and `self`'s
      # in-memory copy stays stale — the controller's subsequent
      # `broadcast_timer` / response then carries the pre-chain state,
      # and the FE (which applies broadcasts in order, last-write-wins
      # via force:true) ends up showing the stale view. Specifically:
      # Phase's `phase-disable-swarm` chain targets Phase itself, and
      # Swarm's `swarm-disable` chain targets Swarm itself — both routes
      # were silently producing the wrong UI until the user reloaded.
      target = self if target.id == id

      case t[:op].to_s
      when "start"     then target.start!
      when "pause"     then target.pause!
      when "resume"    then target.resume!
      when "reset"     then target.reset!
      when "increment"
        if target.dial?   then target.advance_dial!(by: t[:by] || 1)
        elsif target.counter? then target.apply_increment!(by: t[:by] || 1)
        end
      when "goto"
        target.goto_dial_section!(t[:section]) if target.dial?
      when "disable"         then target.update!(disabled: true)
      when "enable"          then target.update!(disabled: false)
      when "toggle_disabled" then target.update!(disabled: !target.disabled)
      end
      target.broadcast(reason: :chained)
    end
  end

  def notification_url
    timer_page&.slug ? "/timers/page/#{timer_page.slug}" : "/timers"
  end

  # Broadcasts to owner-side MonitorChannel only. Public share viewers
  # reconcile via HTTP polling (`/t/:token/sync`) since ActionCable
  # rejects unauthenticated connections in this app.
  #
  # Includes the timer's serialized state inline so receivers can apply
  # it directly without a follow-up /sync round-trip — same payload
  # shape as the controller's `broadcast_timer` helper.
  def broadcast(reason:, extra: {})
    MonitorChannel.broadcast_to(user, {
      id:        :timers,
      channel:   :timers,
      timestamp: Time.current.to_i,
      data:      {
        reason:    reason,
        timer_id:  id,
        timer:     TimerSerializer.new(self, viewer: user).as_json,
        server_ts: Time.current.iso8601(3),
      }.merge(extra),
    })
  end

  private

  def dial_step_count
    cfg = (dial_config || {}).deep_symbolize_keys
    sections = Array(cfg[:sections])
    return 0 if sections.empty?

    sections.sum { |sec| Array(sec[:subs]).any? ? sec[:subs].length : 1 }
  end

  def maybe_fire_counter_event!(direction:)
    return if direction.zero?

    # Fire :complete once when the counter EXACTLY hits a bound — useful
    # as a "reached goal" signal. We don't cap the value: the user can
    # keep going past.
    hit_max = max_value.present? && value == max_value && direction.positive?
    hit_min = min_value.present? && value == min_value && direction.negative?
    fire_callbacks!(event: :complete) if hit_max || hit_min
  end

  def min_le_max_when_set
    return if min_value.nil? || max_value.nil?

    errors.add(:max_value, "must be greater than or equal to min_value") if max_value < min_value
  end
end
