Buddy::Tools.register(
  name:        :cancel_timer,
  description: <<~TXT,
    Stop a countdown that's currently running, paused, or ringing. Use for
    "cancel my timer", "stop the pasta timer", "kill all the timers", "never
    mind that countdown". `match` is a substring of the timer's label, its
    numeric id from `running_timers`, or "all" to clear every one of them.

    This only reaches timers YOU set (the ones in `running_timers`) - their
    ordinary timer board is theirs. Read `running_timers` first if you need to
    know what's on the clock; with nothing running, say that rather than
    implying you can't reach them.

    A timer is a countdown. For a nudge at a clock time use `cancel_reminder`
    instead - "cancel my 3pm" is that, not this.
  TXT
  args: {
    match: { type: :string, required: true, description: "Substring of the label, numeric id, or \"all\"" },
  },
  # Matches whatever is on the clock right now, which is never the same set
  # twice - a saved copy would stop a timer they hadn't set yet.
  routinable: false,
  confirm: ->(payload, ctx) {
    needle = payload[:match].to_s.strip
    live   = Buddy::Timers.live_for(ctx.user).to_a
    raise "nothing is running right now" if live.empty?

    matched = if needle.match?(/\A(?:all|everything|them all|both)\z/i)
      live
    elsif needle.match?(/\A\d+\z/)
      live.select { |t| t.id == needle.to_i }
    else
      live.select { |t| t.name.to_s.downcase.include?(needle.downcase) }
    end

    # An unlabelled timer can't be matched by name, and it's the commonest kind
    # ("5m" with nothing after it). When exactly one is running, a request to
    # stop a timer can only mean that one, whatever they called it.
    matched = live if matched.empty? && live.one?
    raise "no timer matching #{needle.inspect}" if matched.empty?

    named   = matched.filter_map { |t| t.name.to_s.strip.presence }
    summary = if matched.length > 1
      "Stop all #{matched.length} timers?"
    elsif named.any?
      "Stop the #{named.first} timer?"
    else
      "Stop the timer?"
    end

    { summary: summary, resolved: { timer_ids: matched.map(&:id) } }
  },
  label: ->(payload, _ctx) {
    count = Array(payload[:timer_ids]).length
    count > 1 ? "Stop #{count} timers" : "Stop timer"
  },
  execute: ->(payload, ctx) {
    stopped = Array(payload[:timer_ids]).filter_map { |id|
      timer = ctx.user.timers.unscope(where: :archived_at).find_by(id: id)
      next if timer.nil? || !Buddy::Timers.buddy_timer?(ctx.user, timer)

      Buddy::Timers.stop!(timer)
      timer
    }
    # Most timers are unlabelled ("5m" with nothing after it), so the count is
    # taken from the timers themselves - deriving it from the names would
    # report zero for exactly the commonest case.
    { stopped: stopped.length, labels: stopped.filter_map { |t| t.name.to_s.strip.presence } }
  },
  # Stopping a countdown is small and instantly obvious - the chip vanishes off
  # the hero - so it runs on a receipt rather than a confirmation checkbox.
  auto:    true,
  receipt: ->(result, _ctx) {
    labels = Array(result[:labels])
    count  = result[:stopped].to_i
    next "Nothing was running" if count.zero?
    next "Stopped the #{labels.first} timer ⏹" if count == 1 && labels.one?
    next "Timer stopped ⏹" if count == 1

    "Stopped #{count} timers ⏹"
  },
)
