module BowlingScorer
  module_function

  def convert_game_string_to_db_frames(game)
    game.frames.each_with_index do |frame, idx|
      db_frame = game.new_frames.find_or_initialize_by(frame_num: idx + 1)

      db_frame.update!(tosses_to_attributes(idx + 1, frame))
    end
  end

  def tosses_to_attributes(num, tosses)
    spare = false
    strike = false

    spare = tosses.include?("/")
    strike = tosses.include?("X")
    tosses = tosses.map { |toss| toss.gsub("-", "0").gsub("X", "10") }
    if tosses.include?("/")
      spare_idx = tosses.index("/")
      tosses[spare_idx] = 10 - tosses[spare_idx - 1].to_i
    end

    {
      frame_num: num,
      spare:     spare,
      strike:    strike,
      throw1:    tosses[0],
      throw2:    tosses[1],
      throw3:    tosses[2],
    }
  end

  def params_to_attributes(frame_params)
    frame = frame_params[:frame_num].to_i
    spare = false
    strike = false

    toss1, toss2, toss3 = 3.times.map { |t|
      throw_remaining = JSON.parse(frame_params[:"throw#{t + 1}_remaining"]) rescue nil
      toss = frame_params[:"throw#{t + 1}"].to_s
      score = toss.gsub("-", "0").gsub("X", "10")
      spare = toss == "/"
      strike = toss == "X"
      if score == "/"
        prev_score = frame_params[:"throw#{t}"].to_s.gsub("-", "0").to_i
        score = 10 - prev_score
      end

      {
        na:     throw_remaining.nil?,
        closed: spare || strike || throw_remaining == [],
        count:  throw_remaining&.count || 10, # 10 so that `nil` becomes 10 remaining
        pins:   throw_remaining,
        score:  score.presence&.to_i,
      }
    }

    toss1[:score] ||= toss1[:na] ? nil : 10 - toss1[:count]
    toss2[:score] ||= if toss2[:na]
      nil
    elsif frame == 10 && toss1[:closed]
      10 - toss2[:count]
    else
      10 - toss1[:score] - toss2[:count]
    end
    toss3[:score] ||= if frame < 10 || toss3[:na]
      nil
    elsif toss2[:closed]
      10 - toss3[:count]
    else
      10 - toss2[:score] - toss3[:count]
    end

    strike = toss1[:closed] || (toss2[:closed] && toss3[:closed])
    spare = toss2[:closed] || (!strike && toss3[:closed])
    split = split?(toss1[:pins])
    split ||= frame_params[:frame_num] == 10 && toss1[:closed] && split?(toss2[:pins])

    {
      frame_num:        frame_params[:frame_num],
      spare:            spare,
      strike:           strike,
      split:            split,
      throw1:           toss1[:score],
      throw2:           toss2[:score],
      throw3:           toss3[:score],
      throw1_remaining: toss1[:pins],
      throw2_remaining: toss2[:pins],
      throw3_remaining: toss3[:pins],
      strike_point:     frame_params[:strike_point],
    }
  end

  def split?(pins)
    return false if pins.nil?
    return false if pins.include?(1)

    columns = [
      [7],
      [4],
      [2, 8],
      [1, 5],
      [3, 9],
      [6],
      [10],
    ]

    columns.map { |col|
      col.intersect?(pins) ? "1" : "0"
    }.join.match?(/10+1/)
  end

  def game_to_throws(game) # LaneTalk style flat array of each throw
    game.frame_details.map(&:rolls).map.with_index { |f, i|
      i < 9 && f[0] == "X" ? ["X", ""] : f.compact # Convert non-10th strikes to [X, ""]
    }.flatten.map { |n|
      n == n.to_i.to_s ? n.to_i : n # Convert numbers to ints
    }
  end

  def score(frames)
    # Expects either an array of scores like "6/" or a long string of the same delimited with |
    frames = frames.split("|") if frames.is_a?(String)

    score = 0
    frames.each_with_index do |bowl_frame, frame_idx|
      tosses = tosses_from_frame(bowl_frame)

      tosses.each_with_index do |toss, toss_idx|
        toss_score = score_from_toss(toss_idx, tosses)
        score += toss_score

        next unless frame_idx != 9 # tenth frame

        if ["X", "/"].include?(toss)
          next_frame_tosses = tosses_from_frame(frames[frame_idx + 1])

          score += score_from_toss(0, next_frame_tosses) || 0
        end
        next unless toss == "X"

        next_frame_tosses = tosses_from_frame(frames[frame_idx + 1])

        if next_frame_tosses[1].nil?
          next_frame_tosses = tosses_from_frame(frames[frame_idx + 2])
          score += score_from_toss(0, next_frame_tosses) || 0
        else
          score += score_from_toss(1, next_frame_tosses) || 0
        end
      end
      # puts "#{frame_idx + 1}: #{score}"
    end

    score
  end

  def tosses_from_frame(bowl_frame)
    bowl_frame.is_a?(String) ? bowl_frame.chars : bowl_frame
  end

  def score_from_toss(toss_idx, tosses)
    return if tosses.nil?

    toss = tosses[toss_idx]

    return if toss.nil?

    return 0 if toss == "-"
    return 10 if toss == "X"
    return 10 - tosses[toss_idx - 1].to_i if toss == "/"

    toss.to_i
  end
end
