module EventAnalyzer
  module_function

  def durations_between(shower_action)
    ::ActionEvent.order(created_at: :desc)
      .search_data_actions_all(shower_action)
      .each_cons(2).with_object({}) { |(a, b), obj|
        obj[a.timestamp] = duration(a.timestamp - b.timestamp)
      }
  end

  def duration(left, sig_figs=2)
    left = left.to_i
    return "<1s" if left < 1

    time_lengths = {
      s: 1.second.to_i,
      m: 1.minute.to_i,
      h: 1.hour.to_i,
      d: 1.day.to_i,
      w: 1.week.to_i,
    }

    time_lengths.reverse_each.with_object([]) { |(time, length), durations|
      next if length > left
      next if durations.length >= sig_figs

      count = (left / length).round
      left -= count * length

      durations << "#{count}#{time}"
    }.join(" ")
  end
end
