module Buddy
  # Which hot chore a board's pet is dreaming of right now, if any. The board
  # draws again every half hour, weighted the way the morning hot picks are
  # (each item carries its `hot_weight`), with a slot for dreaming of nothing so
  # the bubble isn't always up. The draw is seeded by the half hour and the
  # board, so every screen showing a board agrees, and the page can open already
  # wearing the face the script is about to pick.
  #
  # The board's script makes the same draw in buddy/dream.js#pickChoreDream;
  # the two must stay identical, and spec/javascript/board_dream_spec.rb holds
  # them to it.
  module BoardDream
    module_function

    # How long a dream lasts and how long the pet rests between them, in
    # minutes: the choices a board offers. The defaults are a fresh draw every
    # half hour with no set break.
    DREAM_MINUTES = [15, 30, 60, 120].freeze
    BREAK_MINUTES = [0, 30, 60, 120, 240].freeze
    DEFAULT_DREAM_MINUTES = 30
    DEFAULT_BREAK_MINUTES = 0
    # The weight of dreaming of nothing - one ordinary chore's worth.
    REST_WEIGHT = 1.0
    MASK = 0xFFFFFFFF

    # The chosen item, or nil for nothing right now (a break, or the draw
    # landing on rest).
    def pick(
      items,
      board_id,
      at: Time.current,
      dream_minutes: DEFAULT_DREAM_MINUTES,
      break_minutes: DEFAULT_BREAK_MINUTES)
      pool = candidates(items)
      return nil if pool.empty?

      ms = (at.to_f * 1000).floor
      dream_ms = dream_minutes * 60_000
      cycle_ms = dream_ms + (break_minutes * 60_000)
      return nil if ms % cycle_ms >= dream_ms

      total = pool.sum { |item| item[:hot_weight].to_f } + REST_WEIGHT
      roll = random(seed(board_id, ms / cycle_ms)) * total
      pool.find { |item|
        roll -= item[:hot_weight].to_f
        roll.negative?
      }
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
