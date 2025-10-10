module AllBowlingScoresGenerator
  module_function

  def all_games
    # http://www.balmoralsoftware.com/bowling/bowling.htm
    return # While this will theoretically work, there are 5,726,805,883,325,784,576 scores.
    # This will take a very long time to compute.
    games = []

    all_frame.each do |first|
      all_frame.each do |sec|
        all_frame.each do |thi|
          all_frame.each do |fou|
            all_frame.each do |fif|
              all_frame.each do |six|
                all_frame.each do |sev|
                  all_frame.each do |eig|
                    all_frame.each do |nin|
                      tenth_frame.each do |ten|
                        games << [first, sec, thi, fou, fif, six, sev, eig, nin, ten]
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    games
  end

  def all_frame
    @all_frame ||= (
      # Not 10th frame
      # 11 to include both 0 and 10
      11.times.map { |t|
        toss1 = t
        (11 - t).times.map { |i|
          toss2 = i
          toss2 = "/" if t + i == 10
          toss2 = "-" if i.zero?
          toss1 = "X" if t == 10
          toss1 = "-" if t.zero?
          toss2 = nil if t == 10

          [toss1, toss2].compact.join
        }
      }.flatten
    )
  end

  def tenth_frame
    @tenth_frame ||= (
      tosses = []

      11.times.map { |t|
        current_frame = []
        toss1 = t
        toss1 = "X" if t == 10
        toss1 = "-" if t.zero?

        11.times.map { |i|
          toss2 = i
          toss2 = "/" if t != 10 && t + i == 10
          toss2 = "X" if t == 10 && i == 10
          toss2 = "-" if i.zero?
          next if t != 10 && t + i > 10 # Skip invalid frames

          if t != 10 && t + i < 10 # No 3rd toss
            current_frame = [toss1, toss2].join
            tosses << current_frame unless tosses.include?(current_frame)
            next
          end

          11.times.map { |j|
            toss3 = j
            toss3 = "/" if t == 10 && i != 10 && i + j == 10
            toss3 = "X" if (["X", "/"].include?(toss2)) && j == 10
            toss3 = "-" if j.zero?
            next if t == 10 && i != 10 && i + j > 10 # Skip invalid frames

            tosses << [toss1, toss2, toss3].join
          }
        }
      }

      tosses
    )
  end
end
