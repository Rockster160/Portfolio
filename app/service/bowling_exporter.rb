module BowlingStats
  module_function

  def export(league)
    league.as_json(
      include: {
        bowlers: {
          # bowler_sets
          # games
        },
        sets: {
          include: {
            bowler_sets: {},
            games: {
              except: :frame_details,
              include: :new_frames,
            },
          }
        },
      }
    ).deep_symbolize_keys
  end

  def import(league_data)
  end

  def backup(league)
    import(export(league))
  end
end
