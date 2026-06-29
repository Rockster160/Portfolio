# Global on/off for every outbound Tesla call. Flipped via:
#   - Rails console: `TeslaSwitch.disable!` / `TeslaSwitch.enable!`
#   - Slack link in every Tesla error post (routes to /tesla/switch)
#
# When OFF, every entry point in TeslaControl / Oauth::TeslaApi /
# Jil::Methods::Tesla short-circuits before making a network call. A single
# "Tesla is muted" reminder posts to Slack per UTC day so a forgotten mute
# can't go unnoticed forever.
module TeslaSwitch
  module_function

  CACHE_KEY = :tesla_switch
  REMINDER_INTERVAL = 24.hours

  def enabled?  = !disabled?
  def disabled? = state[:disabled] == true

  def disable!(reason: nil)
    write(disabled: true, disabled_at: Time.current.to_i, reason: reason.presence)
  end

  def enable!
    write(disabled: false, disabled_at: nil, reason: nil, last_muted_reminder_at: nil)
  end

  def disabled_at
    ts = state[:disabled_at]
    ts.present? ? Time.zone.at(ts.to_i) : nil
  end

  def reason
    state[:reason].presence
  end

  # Called by guards when a blocked attempt happens. Posts a "Tesla muted"
  # Slack reminder at most once per REMINDER_INTERVAL so the user remembers
  # the switch is off when they expected something to happen.
  def maybe_remind_muted!(attempted)
    return if enabled?

    last = state[:last_muted_reminder_at].to_i
    return if last > REMINDER_INTERVAL.ago.to_i

    write(last_muted_reminder_at: Time.current.to_i)
    SlackNotifier.notify(<<~MSG)
      :mute: *Tesla is muted* — blocked: `#{attempted}`
      #{reason.present? ? "Reason: _#{reason}_\n" : ""}Re-enable: #{toggle_link(:enable)}
    MSG
  end

  def toggle_link(action)
    base = Rails.env.production? ? "https://ardesian.com" : "http://localhost:3141"
    label = action == :enable ? "🔌 Re-enable Tesla" : "🔇 Mute Tesla"
    "<#{base}/tesla/switch?to=#{action}|#{label}>"
  end

  def state
    (User.me.caches.get(CACHE_KEY) || {}).symbolize_keys
  end

  def write(patch)
    merged = state.merge(patch.symbolize_keys)
    User.me.caches.set(CACHE_KEY, merged.stringify_keys)
    merged
  end
end
