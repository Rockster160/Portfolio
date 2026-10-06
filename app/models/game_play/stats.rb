# Roll/score analysis for one play, one template's history, or one player's
# all-time numbers. Same code serves all three so the end screen, the
# per-game page and the all-time view never disagree with each other.
#
# Dice math uses the EXACT distribution for "NdM" (convolution, not a normal
# approximation) so a 2d6 chart shows the real triangle rather than a smoothed
# curve. Headlines are intentionally plain-language and capped at 4 - this is
# a board game sidekick, not a stats package.
class GamePlay::Stats
  DICE_SPEC = /\A(\d*)d(\d+)\z/i

  def self.for_play(play)
    new(rolls: play.game_rolls.live.ordered.to_a, dice: play.dice).play_stats
  end

  def self.for_template(template)
    plays = template.game_plays.where(status: [:finished, :abandoned])
    rolls = GameRoll.live.where(game_play_id: plays.select(:id)).ordered.to_a
    new(rolls: rolls, dice: template.dice).all_time_stats(plays)
  end

  def self.for_player(user, name)
    plays = user.game_plays.where(status: [:finished, :abandoned])
    rolls = GameRoll.live.where(game_play_id: plays.select(:id), player_name: name).ordered.to_a
    new(rolls: rolls, dice: nil).all_time_stats(plays, player_name: name)
  end

  def initialize(rolls:, dice:)
    @rolls = rolls
    @dice = dice
  end

  def play_stats
    {
      total_rolls:  @rolls.size,
      distribution: distribution(@rolls),
      per_player:   @rolls.group_by(&:player_name).transform_values { |rs| distribution(rs) },
      headlines:    headlines,
      turn_times:   turn_times,
      timeline:     @rolls.map { |r| { value: r.value, player: r.player_name, rolled_at: r.rolled_at.iso8601(3) } },
    }
  end

  def all_time_stats(plays, player_name: nil)
    finished = plays.finished
    win_counts = Hash.new(0)
    finished.find_each do |play|
      Array(play.winner_names).each { |n| win_counts[n] += 1 if player_name.nil? || n == player_name }
    end

    {
      rolls_tracked:         @rolls.size,
      distribution:          distribution(@rolls),
      plays_tracked:         finished.count,
      win_counts:            win_counts,
      avg_duration_minutes:  average(finished.filter_map(&:duration)),
      avg_turn_time_seconds: turn_times[:table_avg],
    }
  end

  private

  def distribution(rolls)
    counts = rolls.each_with_object(Hash.new(0)) { |r, h| h[r.value] += 1 }
    expected = expected_distribution
    values = (counts.keys + expected.keys).uniq.sort
    values.map { |v|
      { value: v, count: counts[v] || 0, expected: expected[v] ? (expected[v] * rolls.size).round(2) : nil }
    }
  end

  # Exact P(sum == v) for n dice of `faces` sides, via convolution. Returns
  # {} for a spec this can't parse (a one-off custom roll, a blank dice) -
  # the actual counts still render, just without the expected overlay.
  def expected_distribution
    @expected_distribution ||= (
      match = DICE_SPEC.match(@dice.to_s.strip)
      if match
        n = match[1].presence&.to_i || 1
        faces = match[2].to_i
        ways = [1]
        n.times do
          next_ways = Array.new(ways.size + faces, 0)
          ways.each_with_index do |w, s|
            next if w.zero?

            (1..faces).each { |f| next_ways[s + f] += w }
          end
          ways = next_ways
        end
        total = faces**n
        ways.each_with_index.with_object({}) { |(w, s), h| h[s] = w.to_f / total if w.positive? }
      else
        {}
      end
    )
  end

  def turn_times
    gaps = Hash.new { |h, k| h[k] = [] }
    @rolls.each_cons(2) { |a, b| gaps[a.player_name] << (b.rolled_at - a.rolled_at) }
    per_player = gaps.transform_values { |secs| average(secs)&.round(1) }
    all_gaps = gaps.values.flatten
    { table_avg: average(all_gaps)&.round(1), per_player: per_player }
  end

  def average(arr)
    return nil if arr.blank?

    (arr.sum.to_f / arr.size)
  end

  def headlines
    lines = []
    lines.concat(fairness_headline)
    lines.concat(hot_value_headlines)
    lines.concat(drought_headline)
    lines.concat(streak_headline)
    lines.concat(turn_time_headline)
    lines.first(4)
  end

  # Chi-square goodness of fit across the whole table vs the dice's own
  # distribution, via the Wilson-Hilferty normal approximation (no gamma
  # function needed) rather than an exact p-value - plenty accurate for a
  # plain-language "fair" / "ran hot" call.
  def fairness_headline
    expected = expected_distribution
    return [] if expected.blank? || @rolls.size < 20

    actual_counts = @rolls.each_with_object(Hash.new(0)) { |r, h| h[r.value] += 1 }
    chi_sq = expected.sum { |v, p|
      e = p * @rolls.size
      next 0 if e <= 0

      (((actual_counts[v] || 0) - e)**2) / e
    }
    k = expected.size - 1
    return [] if k <= 0

    z = (Math.sqrt(2 * chi_sq) - Math.sqrt((2 * k) - 1))
    p_value = 1 - normal_cdf(z)
    return [] if p_value > 0.05

    hot = expected.filter_map { |v, p|
      e = p * @rolls.size
      v if e.positive? && (actual_counts[v] || 0) > e * 1.5
    }
    if hot.any?
      ["the dice ran hot on #{hot.sort.join(" and ")}"]
    else
      ["the dice were unusually uneven this game"]
    end
  end

  # Per player, per value: a one-sided binomial tail probability, corrected
  # for how many (player x value) combinations were checked (Bonferroni) so
  # ordinary noise across a big table doesn't get called unlikely.
  def hot_value_headlines
    expected = expected_distribution
    return [] if expected.blank?

    by_player = @rolls.group_by(&:player_name)
    comparisons = by_player.size * expected.size
    return [] if comparisons.zero?

    candidates = by_player.flat_map { |player, rolls|
      n = rolls.size
      next [] if n < 8

      counts = rolls.each_with_object(Hash.new(0)) { |r, h| h[r.value] += 1 }
      counts.filter_map { |value, count|
        p = expected[value]
        next nil unless p && count > n * p

        tail = binomial_tail(n, count, p)
        corrected = [tail * comparisons, 1.0].min
        next nil if corrected > 0.02

        { player: player, value: value, count: count, expected: (n * p).round(1), p: corrected }
      }
    }
    return [] if candidates.empty?

    top = candidates.min_by { |c| c[:p] }
    odds = (top[:p]).positive? ? (1.0 / top[:p]).round : nil
    text = "#{top[:player]} rolled #{top[:value]} #{top[:count]} times - expected #{top[:expected]}"
    text += ". About a 1-in-#{odds} chance" if odds
    [text]
  end

  def drought_headline
    expected = expected_distribution
    return [] if expected.blank? || @rolls.size < 15

    droughts = expected.keys.map { |value|
      longest = 0
      since_last = 0
      @rolls.each { |r|
        if r.value == value
          longest = [longest, since_last].max
          since_last = 0
        else
          since_last += 1
        end
      }
      longest = [longest, since_last].max
      [value, longest]
    }.max_by { |_v, run| run }

    return [] if droughts.nil? || droughts[1] < 10

    ["no #{droughts[0]} for #{droughts[1]} rolls"]
  end

  def streak_headline
    return [] if @rolls.size < 3

    best_value = nil
    best_len = 0
    current_value = nil
    current_len = 0
    @rolls.each { |r|
      if r.value == current_value
        current_len += 1
      else
        current_value = r.value
        current_len = 1
      end
      if current_len > best_len
        best_len = current_len
        best_value = current_value
      end
    }
    return [] if best_len < 3

    ["#{best_len} #{best_value}s in a row"]
  end

  # Needs a few rounds before "slowest player" means anything - six rolls
  # into a game, a 2-second gap would be called someone's turn length.
  def turn_time_headline
    return [] if @rolls.size < 12

    times = turn_times
    return [] if times[:table_avg].nil? || times[:per_player].blank?

    slowest = times[:per_player].max_by { |_name, secs| secs }
    return [] unless slowest && slowest[1] > times[:table_avg] * 1.4

    ["#{slowest[0]} takes #{format_seconds(slowest[1])} a turn, the table averages #{format_seconds(times[:table_avg])}"]
  end

  def format_seconds(secs)
    secs = secs.to_i
    return "#{secs}s" if secs < 60

    "#{secs / 60}m #{secs % 60}s"
  end

  def normal_cdf(z)
    0.5 * (1 + erf(z / Math.sqrt(2)))
  end

  # Abramowitz & Stegun 7.1.26, max error ~1.5e-7 - plenty for a headline gate.
  def erf(x)
    sign = x.negative? ? -1 : 1
    x = x.abs
    a1, a2, a3, a4, a5 = 0.254829592, -0.284496736, 1.421413741, -1.453152027, 1.061405429
    p = 0.3275911
    t = 1.0 / (1.0 + (p * x))
    y = 1.0 - (((((((((a5 * t) + a4) * t) + a3) * t) + a2) * t) + a1) * t * Math.exp(-x * x))
    sign * y
  end

  def binomial_tail(n, k, p)
    (k..n).sum { |i| binomial_pmf(n, i, p) }
  end

  def binomial_pmf(n, k, p)
    return 0.0 if p <= 0 || p >= 1

    log_coeff = Math.lgamma(n + 1)[0] - Math.lgamma(k + 1)[0] - Math.lgamma(n - k + 1)[0]
    Math.exp(log_coeff + (k * Math.log(p)) + ((n - k) * Math.log(1 - p)))
  end
end
