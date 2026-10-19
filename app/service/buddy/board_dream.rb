module Buddy
  # Which hot chore a board's pet is dreaming of right now, if any. The board
  # draws again every so often (its own pace), weighted the way the morning hot
  # picks are (each item carries its `hot_weight`), with a set chance of
  # dreaming of nothing, a rest after each dream and quiet hours. The draw is
  # seeded by the cycle and the board, so every screen showing a board agrees,
  # and the page can open already wearing the face the script is about to pick.
  #
  # The board's script makes the same draw in buddy/dream.js#pickChoreDream;
  # the two must stay identical, and spec/javascript/board_dream_spec.rb holds
  # them to it.
  module BoardDream
    module_function

    # The choices a board offers (all in minutes but the blank chance): how
    # often it draws, the chance a draw shows nothing, and how long it rests
    # after showing a chore. Quiet hours are clock hours, 0-23, in the board's
    # local time; the same hour twice (or none) means no quiet hours.
    EVERY_MINUTES = [15, 30, 60, 120].freeze
    BLANK_PERCENT = [0, 25, 50, 75].freeze
    REST_MINUTES = [0, 30, 60, 120, 240].freeze
    HOURS = (0..23).to_a.freeze
    DEFAULTS = { every: 30, blank: 25, rest: 0, quiet_from: nil, quiet_to: nil }.freeze
    MASK = 0xFFFFFFFF

    # The chosen item, or nil for nothing right now (quiet hours, a rest, or
    # the draw landing on nothing). `utc_offset` is the board's local offset
    # in minutes, which places its quiet hours.
    def pick(items, board_id, at: Time.current, pace: DEFAULTS, utc_offset: 0)
      pace = DEFAULTS.merge(pace.to_h.symbolize_keys)
      pool = candidates(items)
      return nil if pool.empty?

      ms = (at.to_f * 1000).floor
      return nil if quiet?(ms, pace, utc_offset)

      cycle_ms = pace[:every] * 60_000
      cycle = ms / cycle_ms
      rest_cycles = (pace[:rest].to_f / pace[:every]).ceil
      first = day_first_cycle(cycle * cycle_ms, cycle_ms, utc_offset)
      shown = {}
      (first..cycle).each { |k|
        resting = (([k - rest_cycles, first].max)...k).any? { |j| shown[j] }
        shown[k] = !resting && !quiet?(k * cycle_ms, pace, utc_offset) && draw(pool, board_id, k, pace[:blank])
      }
      shown[cycle] || nil
    end

    # One cycle's draw: nothing `blank` percent of the time, else a hot chore
    # weighted the way the morning hot picks are.
    def draw(pool, board_id, cycle, blank)
      r = random(seed(board_id, cycle))
      cut = blank / 100.0
      return nil if r < cut

      roll = ((r - cut) / (1 - cut)) * pool.sum { |item| item[:hot_weight].to_f }
      pool.find { |item|
        roll -= item[:hot_weight].to_f
        roll.negative?
      } || pool.last
    end

    # Rests are worked out from the board's local midnight: the first cycle
    # starting at or after it. A fixed anchor keeps every screen agreeing on
    # where the rests fall, and the day is short enough to walk.
    def day_first_cycle(ms, cycle_ms, utc_offset)
      local_minutes = (ms / 60_000) + utc_offset
      day_start_ms = (((local_minutes / 1440) * 1440) - utc_offset) * 60_000
      -(-day_start_ms / cycle_ms)
    end

    def quiet?(ms, pace, utc_offset)
      from = pace[:quiet_from]
      to = pace[:quiet_to]
      return false if from.nil? || to.nil? || from == to

      hour = (((ms / 60_000) + utc_offset) / 60) % 24
      from < to ? hour >= from && hour < to : hour >= from || hour < to
    end

    # Hot chores still asking today, in id order so both sides walk them alike.
    def candidates(items)
      Array(items).map { |item| item.to_h.symbolize_keys }.select { |item|
        item[:kind].to_s == "chore" && item[:hot_weight].to_f.positive? &&
          item[:today_visible] && !item[:archived] &&
          item[:progress_count].to_i < item[:target_count].to_i &&
          !item[:skipped_today] && !item[:dismissed]
      }.sort_by { |item| item[:id].to_i }
    end

    def seed(board_id, cycle)
      ((cycle * 31) + board_id.to_i) & MASK
    end

    # mulberry32: a float in [0, 1) from a 32-bit seed, bit for bit the JS one.
    def random(seed)
      a = (seed + 0x6D2B79F5) & MASK
      t = imul(a ^ (a >> 15), 1 | a)
      t = ((t + imul(t ^ (t >> 7), 61 | t)) & MASK) ^ t
      ((t ^ (t >> 14)) & MASK) / 4_294_967_296.0
    end

    def imul(x, y)
      (x * y) & MASK
    end
  end
end
