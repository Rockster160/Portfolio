module BowlingScorer
  module_function

  def split?(pins)
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

    columns.map { |col| (col & pins).any? ? "1" : "0" }.join("").match?(/10+1/)
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

        if frame_idx != 9 # tenth frame
          if toss == "X" || toss == "/"
            next_frame_tosses = tosses_from_frame(frames[frame_idx + 1])

            score += score_from_toss(0, next_frame_tosses) || 0
          end
          if toss == "X"
            next_frame_tosses = tosses_from_frame(frames[frame_idx + 1])

            if next_frame_tosses[1].nil?
              next_frame_tosses = tosses_from_frame(frames[frame_idx + 2])
              score += score_from_toss(0, next_frame_tosses) || 0
            else
              score += score_from_toss(1, next_frame_tosses) || 0
            end
          end
        end
      end
      # puts "#{frame_idx + 1}: #{score}"
    end

    score
  end

  def tosses_from_frame(bowl_frame)
    bowl_frame.is_a?(String) ? bowl_frame.split("") : bowl_frame
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
