module CronParse
  module_function

  def next(cron, user=nil)
    Time.use_zone((user || User).timezone) {
      # Do NOT use commas to split- commas are part of cron syntax, so should not be used for multiple crons
      cron.to_s.split(/\s*\|\s*/).filter_map { |cron_str| resolve_piece(cron_str, user) }.min
    }
  end

  # One `|`-separated piece, and the rescue lives HERE rather than around the
  # whole expression on purpose. A task can name several anchors, and a single
  # piece blowing up used to nil the entire result - so one anchor going wrong
  # took every other anchor's schedule down with it and the task stopped
  # running. A piece that can't answer drops out; the rest still schedule.
  def resolve_piece(cron_str, user)
    # An anchor ("sun:sunset-5m") names a moment cron has no way to express,
    # because the moment is allowed to move. Either kind may appear on either
    # side of a `|`, and the soonest still wins.
    return ::Anchor.resolve(cron_str, user: user) if ::AnchorExpression.parse(cron_str)

    Fugit::Cron.parse(cron_str)&.next_time&.to_i&.then { |i| Time.zone.at(i) }
  rescue NoMethodError => e # parse returns `nil` if it fails, then `next_time` throws an error
    Rails.logger.warn("[CronParse] #{cron_str.inspect}: #{e.class}: #{e.message}")
    nil
  end

  # The anchor keys a cron string depends on, so an anchor that just moved can
  # find the tasks needing re-resolution without matching on raw text.
  def anchors(cron)
    cron.to_s.split(/\s*\|\s*/).filter_map { |str| ::AnchorExpression.parse(str)&.dig(:key) }.uniq
  end

  # Two kinds of wrong, and they are NOT the same kind.
  #
  # A `complaint` is unreadable: no amount of setting things up later makes
  # "sun:sunset-5" mean anything, so it blocks the save rather than becoming a
  # task that silently never runs.
  #
  # A `warning` is readable but not satisfied YET - an anchor that hasn't been
  # created. That's a legitimate half-finished state: the task is the
  # placeholder and the feeder comes after, or the other way round. Blocking it
  # would force people to build in one particular order.

  # nil when every piece is readable; otherwise a sentence naming the first that
  # isn't.
  def complaint(cron, _user=nil)
    cron.to_s.split(/\s*\|\s*/).filter_map { |str| piece_complaint(str.strip) }.first
  end

  # Every anchor this cron names that doesn't exist for `user`, as sentences.
  # Empty when there's nothing to say.
  def warnings(cron, user=nil)
    return [] if user.blank?

    known = ::Anchor.keys_for(user)
    anchors(cron).reject { |key| known.include?(key) }.map { |key| unknown_anchor(key, known) }
  end

  def piece_complaint(str)
    return nil if str.blank?
    return nil if ::AnchorExpression.parse(str)
    return nil if ::Fugit::Cron.parse(str).present?

    # Shaped like an anchor but not readable as one - say so specifically rather
    # than calling it a bad cron, which it was never trying to be.
    ::AnchorExpression.complaint(str) || "couldn't read #{str.inspect} as a cron or an anchor"
  end

  def unknown_anchor(key, known)
    return "#{key} doesn't exist yet. Known anchors: #{known.join(", ")}" if known.any?

    "#{key} doesn't exist yet - create one from a Jil task with " \
      "Anchor.set(#{key.inspect}, <time>)"
  end
end
