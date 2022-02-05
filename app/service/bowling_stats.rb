module BowlingStats
  module_function

  def pickup_ratio(bowler, pins)
    str_pins = "[#{pins.sort.join(",")}]"

    left = bowler.frames.where(throw1_remaining: str_pins)
    # tleft = bowler.frames.where(throw1_remaining: "[]", throw2_remaining: str_pins)

    return "N/A" if left.none?
    "#{((left.where(spare: true).count / left.count.to_f) * 100).round}%"
  end

  def split_conversions(bowler)
    splits = bowler.frames.where(split: true)

    return "N/A" if splits.none?

    "#{((splits.where(spare: true).count / splits.count.to_f) * 100).round}%"
  end

  def split_data(bowler)
    splits = bowler.frames.where(split: true)
    grouped = splits.group(:throw1_remaining, :spare).count(:throw1_remaining)

    counts = grouped.each_with_object({}) do |((pins, spare), count), obj|
      obj[pins] ||= [0, 0]
      obj[pins][0] += count if spare
      obj[pins][1] += count
    end

    counts.map { |pins, (picked, total)| "#{pins}: #{picked}/#{total} (#{((picked/total.to_f)*100).round}%)" }
  end

  def strike_count_frames(count=4)
    # Should filter by league
    # count should default to num of league bowlers
    BowlingFrame
      .where(throw1: 10)
      .joins(:game)
      .group(:set_id, :game_num, :frame_num)
      .count(:id)
      .select { |set_game_frame, num| num == count }
  end

  def missed_drink_frames
    set_game_frames = strike_count_frames(3).keys

    set_game_frames.each_with_object({}) do |(set_id, game_num, frame_num), obj|
      blamed_bowler_id = BowlingFrame.joins(:game).where(
        bowling_frames: { frame_num: frame_num },
        bowling_games: { set_id: set_id, game_num: game_num }
      ).where.not(throw1: 10).take&.game&.bowler_id
      next if blamed_bowler_id.nil?

      obj[blamed_bowler_id] ||= 0
      obj[blamed_bowler_id] += 1
    end
  end
end
