module Buddy
  # A sound played on a board, sent to that board BY NAME. Only screens showing
  # that board play it, so another board watching the same groups, or any other
  # page left open, never takes it.
  #
  # A sound is the notes `beeps` plays in the browser, one after another:
  # `[milliseconds, hertz, volume, wave]`. A rest is a note at 0 Hz and 0
  # volume. Jil builds them from SoundNote blocks (see Jil::Methods::Sound).
  module BoardSound
    module_function

    WAVES = %w[sine square sawtooth triangle].freeze
    # Long enough for Happy Birthday twice over, short enough that a typo in a
    # loop can't hold a board's speaker for an hour.
    MAX_NOTES = 200
    MAX_MILLISECONDS = 10_000
    MAX_HERTZ = 20_000

    # One note, made safe to hand to the browser, or nil when there is nothing
    # to play or wait for.
    def note(value)
      duration, frequency, volume, wave = Array.wrap(value)
      duration = duration.to_f.round.clamp(0, MAX_MILLISECONDS)
      return if duration.zero?

      frequency = frequency.to_f.clamp(0, MAX_HERTZ)
      volume = volume.to_f.clamp(0, 1)
      return [duration, 0, 0, nil] if frequency.zero? || volume.zero?

      wave = wave.to_s.strip.downcase
      [duration, frequency, volume, WAVES.include?(wave) ? wave : WAVES.first]
    end

    # A whole sound: every note that survives `note`, in order.
    def notes(value)
      list = Array.wrap(value)
      # A lone note arrives as its own four numbers rather than a list of them.
      list = [list] if list.first.is_a?(::Numeric)
      list.filter_map { |entry| note(entry) }.first(MAX_NOTES)
    end

    # Plays `sound` on every board `name` points at (see BoardYell.boards_for).
    # Returns the boards it was sent to, none when there is nothing to play.
    def play!(user:, board:, sound:)
      played = notes(sound)
      return [] if played.none? { |entry| entry[1].positive? }

      ::Buddy::BoardYell.boards_for(user, board).each { |target|
        data = { kind: :board_sound, conversation_id: target.id, notes: played }
        ::User.where(id: ::Buddy::BoardYell.viewer_ids(target)).find_each do |viewer|
          ::MonitorChannel.broadcast_to(viewer, { id: :byte, channel: :byte, data: data })
        end
      }
    end
  end
end
