# tracer = Tracer.trace { ::Jil.trigger_now(me, :email, email) }
# puts "Top 10 slowest methods:"
# tracer.slowest(10).each { |method, time| puts "%0.8f s %s" % [time, method] }
# ptable(tracer.table.map { |method, count, total, avg|
#   [
#     method.orange,
#     count.to_s.rjust(5).offgreen + "  ",
#     ("%.8f" % total).light_purple + "  ",
#     ("%.8f" % avg).blue,
#   ]
# })
class Tracer
  include ::Memoizable

  attr_accessor :events

  def self.trace(&)
    new.trace(&)
  end

  def initialize
    @events = []
  end

  def trace(&block)
    raise "Already traced. Call `Tracer.trace` to run again." if @events.any?

    trace_point = TracePoint.new(:call, :return) do |tp|
      @events << {
        event:  tp.event,                                                    # :call or :return
        time:   Process.clock_gettime(Process::CLOCK_MONOTONIC),             # high-res timestamp
        class:  tp.defined_class.to_s.gsub(/#<Class:(.*?)>/, '\1').gsub(/\(.*?\)/, ""),
        method: tp.method_id,
        path:   tp.path,
        lineno: tp.lineno,
      }
    end

    trace_point.enable
    block.call
    trace_point.disable
    self
  end

  def sort_by(&block)
    method_frames.transform_values { |frames| block.call(frames) }.sort_by { |_, time| -time }
  end

  def slowest(limit=10, by: :duration)
    sort_by { |frames| frames.sum { |f| f[by] } }.first(limit)
  end

  def analyze
    method_frames.map { |_, frames|
      base_frame = frames.first
      times = frames.map { |f| f[:start] }
      {
        **base_frame.slice(:method, :path, :lineno),
        **analyze_numbers(frames.map { |f| f[:duration] }),
        earliest: times.min,
        latest:   times.max,
      }
    }
  end

  def table
    analyze.sort_by { |e| -e[:mean] }.map { |e|
      e.values_at(:method, :count, :sum, :mean)
    }
  end

  def analyze_numbers(numbers)
    count  = numbers.size
    sorted = numbers.sort
    sum    = numbers.sum
    mean   = sum.to_f / count
    median =
      if count.odd?
        sorted[count / 2]
      else
        (sorted[(count / 2) - 1] + sorted[count / 2]) / 2.0
      end
    freq      = numbers.tally
    max_freq  = freq.values.max
    mode      = freq.select { |_, v| v == max_freq }.keys
    variance  = numbers.sum { |n| (n - mean)**2 } / count
    std_dev   = Math.sqrt(variance)

    {
      count:              count,              # number of elements
      sum:                sum,                # total
      mean:               mean,               # average
      median:             median,             # middle value
      mode:               mode,               # most frequent value(s)
      variance:           variance,           # average squared deviation
      standard_deviation: std_dev,            # dispersion measure
      range:              sorted.last - sorted.first,  # span
    }
  end

  💾(:relevant_events) { @events.select { |e| e[:path].include?("/app/") } }
  💾(:frames) {
    stack = []
    exclusive_times = []

    relevant_events.each do |e|
      if e[:event] == :call
        # push new frame, track its child time
        stack << e.merge(child_time: 0)
      else
        # pop matching call
        frame = stack.pop
        total = e[:time] - frame[:time]                # total time including children
        self_tm = total - frame[:child_time]             # subtract time spent in subcalls
        exclusive_times << {
          method:   "#{frame[:class]}##{frame[:method]}",
          duration: self_tm,
          total:    total,
          start:    frame[:time],
          path:     "#{frame[:path]}:#{frame[:lineno]}",
        }
        # add this frame’s total into parent’s child_time
        stack.last[:child_time] += total if stack.any?
      end
    end
    exclusive_times.sort_by! { |e| e[:start] }
  }
  💾(:method_frames) {
    frames.group_by { |t| t[:method] }
  }
end
