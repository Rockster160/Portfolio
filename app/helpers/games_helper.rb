module GamesHelper
  # 95 -> "1h 35m", 40 -> "40 min"
  def games_minutes(minutes)
    minutes = minutes.to_i
    return "" unless minutes.positive?

    hours, mins = minutes.divmod(60)
    return "#{mins} min" if hours.zero?

    mins.zero? ? "#{hours}h" : "#{hours}h #{mins}m"
  end

  # Final standings, best first: players (or teams, or the one table score)
  # with their colour and score. Unscored entries sink to the bottom.
  def games_standings(play)
    scores = play.final_scores.to_h
    players = Array(play.players)
    entries = (
      case play.scoring
      when :teams
        scores.map { |team, v|
          color = players.find { |p| (p["team"].presence || p["name"]) == team }&.dig("color")
          { "name" => team, "color" => color, "score" => v }
        }
      when :table
        [{ "name" => "Table", "color" => nil, "score" => scores.values.compact.first }]
      else
        players.map { |p| { "name" => p["name"], "color" => p["color"], "score" => scores[p["name"]] } }
      end
    )
    scored, unscored = entries.partition { |e| e["score"].is_a?(Numeric) }
    scored = scored.sort_by { |e| e["score"] }
    scored = scored.reverse unless play.win == :low
    scored + unscored
  end

  # Wins per player across a game's history, most first. A play finished in
  # the app carries its winners; a hand-logged or backfilled one often has
  # only scores, so its winner is read off them with the game's own rule
  # (none for :none).
  def games_win_counts(rows, win)
    counts = Hash.new(0)
    rows.each do |row|
      winners = Array(row[:winner_names])
      if winners.empty? && [:high, :low].include?(win)
        scores = row[:final_scores].to_h.reject { |name, v| name.blank? || !v.is_a?(Numeric) }
        if scores.any?
          best = win == :low ? scores.values.min : scores.values.max
          winners = scores.select { |_, v| v == best }.keys
        end
      end
      winners.each { |name| counts[name] += 1 }
    end
    counts.sort_by { |name, n| [-n, name] }.to_h
  end
end
