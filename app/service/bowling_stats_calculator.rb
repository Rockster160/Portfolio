class BowlingStatsCalculator
  def self.call(league, set=nil)
    bowlers = league.bowlers.ordered.where(total_games: 1..)
    stats = BowlingStats.new(league, set)
    missed_drinks = stats.missed_drink_frames
    strike_points = [:pocket, :brooklyn, :other].map(&:to_s)

    @stats = {
      "Team Drink Frames":   [[league.team_name, stats.strike_count_frames.length]],
      "Missed Drink Frames": bowlers.map { |bowler| [bowler.name, missed_drinks[bowler.id]] },
      "Ten Pins":            bowlers.map { |bowler|
        pickup = stats.pickup(bowler, [10])
        [bowler.name, "#{pickup[0]}/#{pickup[1]}", stats.percent(*pickup)]
      },
      "Strike Point":        [[nil, *strike_points.map(&:titleize)]] + bowlers.map { |bowler|
        bowler_points = stats.strike_points(bowler)
        [bowler.name, *strike_points.map { |point|
          bowler_points[point == "other" ? nil : point].to_i
        }]
      },
      "Strike Chance":       bowlers.map { |bowler|
        strike_data = stats.pickup(bowler, nil)
        [bowler.name, "#{strike_data[0]}/#{strike_data[1]}", stats.percent(*strike_data)]
      },
      "Spare Conversions":   bowlers.map { |bowler|
        spare_data = stats.spare_data(bowler)
        [bowler.name, "#{spare_data[0]}/#{spare_data[1]}", stats.percent(*spare_data)]
      },
      "Closed Games":        bowlers.map { |bowler|
        closed_data = stats.closed_games(bowler)
        [bowler.name, "#{closed_data[0]}/#{closed_data[1]}", stats.percent(*closed_data)]
      },
      "Splits Converted":    bowlers.map { |bowler| [bowler.name, *stats.split_data(bowler)] },
    }
  end
end
