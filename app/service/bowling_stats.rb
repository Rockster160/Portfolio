class BowlingStats

  def self.pickup(bowler, str_pins)
    new(nil).pickup(bowler, str_pins)
  end

  delegate :pickup, to: :class

  def initialize(league, set=nil)
    @league = league
    @set = set
  end

  def percent(num, total, round: 0)
    return "N/A" unless total&.positive?

    "#{((num / total.to_f)*100).round(round)}%"
  end

  def pickup(bowler, str_pins)
    if str_pins.nil?
      [frames(bowler).where(strike: true).count, frames(bowler).count]
    else
      str_pins = JSON.parse(str_pins) rescue str_pins
      str_pins = "[#{str_pins.sort.join(", ")}]" unless str_pins.is_a?(String)

      left = frames(bowler).where(throw1_remaining: str_pins)
      # tleft = frames(bowler).where(throw1_remaining: "[]", throw2_remaining: str_pins)

      [left.where(spare: true).count, left.count]
    end
  end

  def frames(bowler)
    if @set.present?
      bowler.frames.joins(:set).where(bowling_sets: { id: @set.id })
    else
      bowler.frames
    end
  end

  def spare_data(bowler)
    [frames(bowler).where(spare: true).count, frames(bowler).where(strike: false).count]
  end

  def closed_games(bowler)
    games = @set.present? ? bowler.games.where(set: @set) : bowler.games
    closed_frame_count_sql = "
      COUNT(bowling_frames.id) FILTER(
        WHERE(
          bowling_frames.strike IS true OR bowling_frames.spare IS true
        )
      )
    "

    closed_games = games.left_joins(:new_frames).attended.
      select("bowling_games.id, #{closed_frame_count_sql} AS closed_frame_count").
      having("#{closed_frame_count_sql} = 10").
      group("bowling_games.id")
      # map { |game_id, closed_count| game = BowlingGame.find(game_id); "https://ardesian.com/bowling/#{game.set_id}/edit?game=#{game.game_num}&bowler_id=#{game.bowler_id}" }
      # .map { |c| [c.id, c.closed_frame_count] }

    [closed_games.length, games.attended.count]
  end

  def split_conversions(bowler)
    splits = frames(bowler).where(split: true)

    return "N/A" if splits.none?

    "#{((splits.where(spare: true).count / splits.count.to_f) * 100).round}%"
  end

  def split_data(bowler)
    splits = frames(bowler).where(split: true)
    grouped = splits.group(:throw1_remaining, :spare).count(:throw1_remaining)

    counts = grouped.each_with_object({}) do |((pins, spare), count), obj|
      obj[pins] ||= [0, 0]
      obj[pins][0] += count if spare
      obj[pins][1] += count
    end.sort_by { |pins, (picked, total)| pins.length }.sort_by { |pins, (picked, total)| -total }

    counts.map { |pins, (picked, total)|
      {
        pins: JSON.parse(pins),
        picked: picked,
        total: total,
        ratio: "#{((picked/total.to_f)*100).round}%",
      }
    }
  end

  def set_strike_frames(set, missed=0, min=2)
    set.frames.
      where(throw1: 10).
      joins(:game).
      group("bowling_games.set_id", "bowling_games.game_num", "bowling_frames.frame_num").
      count(:id).
      select { |set_game_frame, num|
        next if num < min
        num == (set.games.attended.where(game_num: set_game_frame[1]).count - missed)
      }
  end

  def strike_count_frames(missed=0)
    return set_strike_frames(@set, missed) if @set.present?

    {}.tap do |set_game_frames|
      @league.sets.order(:created_at).joins(:games).distinct.each do |set|
        set_game_frames.merge!(set_strike_frames(set, missed))
      end
    end
  end

  def missed_drink_frames
    # ActiveRecord::Base.logger.level = 1
    # ActiveRecord::Base.logger.level = 0
    set_game_frames = strike_count_frames(1).keys

    set_game_frames.each_with_object({}) do |(set_id, game_num, frame_num), obj|
      blamed_bowler_id = BowlingFrame.joins(:game).where(
        bowling_frames: { frame_num: frame_num },
        bowling_games: { set_id: set_id, game_num: game_num, absent: [nil, false] }
      ).where.not(throw1: 10).take&.game&.bowler_id
      next if blamed_bowler_id.nil?

      obj[blamed_bowler_id] ||= 0
      obj[blamed_bowler_id] += 1
    end
  end
end
