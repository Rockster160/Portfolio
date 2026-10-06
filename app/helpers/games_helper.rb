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
end
