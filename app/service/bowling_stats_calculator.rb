class BowlingStatsCalculator

  def self.call(league)
    bowlers = league.bowlers.ordered
    missed_drinks = BowlingStats.missed_drink_frames(league)

    @stats = {
      "Team Drink Frames": [[league.team_name, BowlingStats.strike_count_frames(league).length]],
      "Missed Drink Frames": bowlers.map { |bowler| [bowler.name, missed_drinks[bowler.id]] },
      "Ten Pins": bowlers.map { |bowler|
        pickup = BowlingStats.pickup(bowler, [10])
        [bowler.name, "#{pickup[0]}/#{pickup[1]}", BowlingStats.percent(*pickup)]
      },
      "Strike Chance": bowlers.map { |bowler|
        strike_data = BowlingStats.pickup(bowler, nil)
        [bowler.name, "#{strike_data[0]}/#{strike_data[1]}", BowlingStats.percent(*strike_data)]
      },
      "Spare Conversions": bowlers.map { |bowler|
        spare_data = BowlingStats.spare_data(bowler)
        [bowler.name, "#{spare_data[0]}/#{spare_data[1]}", BowlingStats.percent(*spare_data)]
      },
      "Closed Games": bowlers.map { |bowler|
        closed_data = BowlingStats.closed_games(bowler)
        [bowler.name, "#{closed_data[0]}/#{closed_data[1]}", BowlingStats.percent(*closed_data)]
      },
      "Splits Converted": bowlers.map { |bowler| [bowler.name, *BowlingStats.split_data(bowler)] },
    }
  end

  def self.set(set)
    league = set.league
    bowlers = league.bowlers.ordered
    missed_drinks = BowlingSetStats.missed_drink_frames(set)

    @stats = {
      "Team Drink Frames": [[league.team_name, BowlingSetStats.set_strike_frames(set).length]],
      "Missed Drink Frames": bowlers.map { |bowler| [bowler.name, missed_drinks[bowler.id]] },
      "Ten Pins": bowlers.map { |bowler|
        pickup = BowlingSetStats.pickup(bowler, set, [10])
        [bowler.name, "#{pickup[0]}/#{pickup[1]}", BowlingSetStats.percent(*pickup)]
      },
      "Strike Chance": bowlers.map { |bowler|
        strike_data = BowlingSetStats.pickup(bowler, set, nil)
        [bowler.name, "#{strike_data[0]}/#{strike_data[1]}", BowlingSetStats.percent(*strike_data)]
      },
      "Spare Conversions": bowlers.map { |bowler|
        spare_data = BowlingSetStats.spare_data(bowler, set)
        [bowler.name, "#{spare_data[0]}/#{spare_data[1]}", BowlingSetStats.percent(*spare_data)]
      },
      "Closed Games": bowlers.map { |bowler|
        closed_data = BowlingSetStats.closed_games(bowler, set)
        [bowler.name, "#{closed_data[0]}/#{closed_data[1]}", BowlingSetStats.percent(*closed_data)]
      },
      "Splits Converted": bowlers.map { |bowler| [bowler.name, *BowlingSetStats.split_data(bowler, set)] },
    }
  end
end
