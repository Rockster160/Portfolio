class ChartBuilder
  # Validated categorical palette (dark surface #161B22): worst adjacent CVD
  # ΔE 8.4, normal-vision ΔE 19.3, all >= 3:1 contrast. See the dataviz skill.
  PALETTE = %w[#3987e5 #008300 #d55181 #c98500 #199e70 #d95926 #9085e9 #e66767].freeze
  # Sign split reads as polarity: charges (positive) warm/red, deposits (negative) cool/blue.
  POSITIVE_COLOR = "#e66767".freeze
  NEGATIVE_COLOR = "#3987e5".freeze

  def initialize(chart, start_at: nil, end_at: nil, bucket: nil, range: nil)
    @chart = chart
    @override_start = start_at
    @override_end = end_at
    @override_bucket = bucket.presence&.to_sym
    @override_range = range.presence
  end

  def call
    @chart.user.timezone {
      datasets = series_defs.map.with_index { |sdef, idx|
        {
          label: sdef[:label],
          data:  (bucket == :none ? point_data(sdef) : bucket_data(sdef)),
          # User-defined color for this series wins, then a semantic color (sign),
          # then the validated categorical palette.
          color: @chart.colors[sdef[:label]].presence || sdef[:color] || PALETTE[idx % PALETTE.size],
          # Stack group: negated (burn) series stack together in one bar, positive
          # in another — so a stacked chart shows the two side by side per bucket.
          stack: (sdef[:negate] ? "neg" : "pos"),
        }
      }

      {
        labels:      (bucket == :none ? nil : labels),
        datasets:    datasets,
        time_axis:   bucket == :none,
        chart_type:  @chart.chart_type,
        unit:        @chart.unit,
        metric:      @chart.metric,
        bucket:      bucket,
        range_label: range_label,
        window:      window_bounds,
        markers:     markers,
        buckets_ms:  buckets_ms,
        stats:       stats,
      }
    }
  rescue ActiveRecord::StatementInvalid
    {
      labels:     [],
      datasets:   [],
      time_axis:  false,
      chart_type: @chart.chart_type,
      unit:       @chart.unit,
      stats:      {},
      error:      "Invalid query syntax",
    }
  end

  private

  def bucket
    @bucket ||= (@override_bucket || @chart.bucket)
  end

  # Events matching one breaker query. For :gap we need full history (so a gap
  # straddling the range start is still accurate) and filter afterward; otherwise
  # we limit in SQL. Memoized per query string so multi-query charts don't reload.
  def load(query)
    @loaded ||= {}
    @loaded[query] ||= (
      scope = @chart.user.action_events
      scope = scope.query(query) if query.present?
      # `query` drops the relation scope, so re-apply user filtering (see #pullups).
      scope = scope.where(user: @chart.user).order(:timestamp)
      scope = scope.where(timestamp: range) if range && @chart.metric != :gap
      scope.to_a
    )
  end

  # Every matched event (union across queries), for full-span and header stats.
  def all_events
    @all_events ||= (
      if @chart.queries.present?
        @chart.queries.flat_map { |q| q[:query] ? load(q[:query]) : [] }.uniq(&:id)
      else
        load(@chart.query)
      end
    )
  end

  def in_range_events
    @in_range_events ||= all_events.select { |evt| in_range?(evt.timestamp) }
  end

  # Splits the matched events into one definition per dataset.
  def series_defs
    # Explicit multi-query charts: each query is its own series (X vs Z as lines).
    if @chart.queries.present?
      return @chart.queries.map { |q|
        { label: q[:label], events: (q[:query] ? load(q[:query]) : []), negate: q[:negate], daily: q[:daily] }
      }
    end

    case @chart.series_by
    when :name
      all_events.group_by(&:name).map { |name, evts| { label: name, events: evts } }
    when :notes
      # One series per distinct notes value (e.g. a line per note across all Z events).
      grouped = all_events.group_by { |evt| evt.notes.to_s.strip }
      grouped.map { |note, evts| { label: note.presence || "(no notes)", events: evts } }
    when :data_keys
      keys = all_events.flat_map { |evt| evt.data.is_a?(Hash) ? evt.data.keys : [] }.uniq
      keys.map { |key| { label: key, events: all_events, data_key: key } }
    when :sign
      # Plot magnitudes (abs) so the two arms sit on one shared axis and their
      # heights compare directly — never a second/mirrored y-axis.
      [
        { label: "Positive", events: all_events.select { |evt| value_for(evt) >= 0 }, color: POSITIVE_COLOR, abs: true },
        { label: "Negative", events: all_events.select { |evt| value_for(evt).negative? }, color: NEGATIVE_COLOR, abs: true },
      ]
    else
      [{ label: @chart.name, events: all_events }]
    end
  end

  # The number a single event contributes. `data_key` (from a data_keys series)
  # overrides the chart's configured value_source.
  def value_for(event, data_key=nil)
    key = data_key || (@chart.value_source == :data ? @chart.data_key : nil)

    if key.present?
      event.data.is_a?(Hash) ? event.data[key].to_f : 0.0
    elsif @chart.value_source == :notes
      event.notes.to_f
    else
      1.0
    end
  end

  # --- Point mode (bucket == :none): one mark per event, time x-axis ---

  def point_data(sdef)
    return [] if sdef[:daily] # synthetic daily series is bucket-only

    if @chart.metric == :gap
      gap_deltas(sdef[:events]).filter_map { |time, days|
        next unless in_range?(time)

        { x: time.to_i * 1000, y: signed(days, sdef) }
      }
    else
      sdef[:events].filter_map { |evt|
        next unless in_range?(evt.timestamp)

        value = value_for(evt, sdef[:data_key])
        { x: evt.timestamp.to_i * 1000, y: signed(sdef[:abs] ? value.abs : value, sdef) }
      }
    end
  end

  # --- Bucket mode: aggregate into dense date buckets, category x-axis ---

  def bucket_data(sdef)
    # Synthetic flat series (e.g. RMR): N per day, summed over each bucket's days.
    return bucket_starts.map { |start| signed(sdef[:daily] * days_in_bucket(start), sdef) } if sdef[:daily]

    if @chart.metric == :gap
      grouped = gap_deltas(sdef[:events]).group_by { |time, _days| bucket_key(time) }
      bucket_starts.map { |start|
        deltas = grouped[start]
        next nil if deltas.blank?

        signed((deltas.sum { |_time, days| days } / deltas.length.to_f).round(1), sdef)
      }
    else
      grouped = sdef[:events].group_by { |evt| bucket_key(evt.timestamp) }
      bucket_starts.map { |start| signed(aggregate(grouped[start] || [], sdef), sdef) }
    end
  end

  # Negates a series value when the series is marked burn (leading "-").
  def signed(value, sdef)
    return value if value.nil?

    sdef[:negate] ? -value : value
  end

  def days_in_bucket(start)
    case bucket
    when :day   then 1
    when :week  then 7
    when :month then Time.days_in_month(start.month, start.year)
    when :year  then (Date.gregorian_leap?(start.year) ? 366 : 365)
    else 1
    end
  end

  def aggregate(events, sdef)
    key = sdef[:data_key]
    values = events.map { |evt| value_for(evt, key) }

    case @chart.metric
    when :count then events.length
    when :sum   then values.sum.round(2)
    when :avg   then values.empty? ? nil : (values.sum / values.length.to_f).round(2)
    when :min   then values.min
    when :max   then values.max
    end.then { |result|
      # Sign series plot magnitudes so both arms compare on one axis.
      result = result.abs if result && sdef[:abs]
      # Empty buckets read as 0 for additive metrics, as a line-gap otherwise.
      result || (@chart.metric.in?(%i[sum count]) ? 0 : nil)
    }
  end

  # Consecutive [time, days-since-previous] pairs over the full series history.
  def gap_deltas(events)
    events.sort_by(&:timestamp).each_cons(2).map { |prev, curr|
      [curr.timestamp, ((curr.timestamp - prev.timestamp) / 1.day).round(1)]
    }
  end

  # Events matching the marker query — drawn as vertical reference lines (e.g. every
  # K event) with name/notes/date carried through for the hover tooltip.
  def markers
    return [] if @chart.marker_query.blank?

    load(@chart.marker_query).filter_map { |evt|
      next unless in_range?(evt.timestamp)

      {
        ts:    evt.timestamp.to_i * 1000,
        name:  evt.name,
        notes: evt.notes.to_s,
        date:  evt.timestamp.strftime("%b %-d, %Y %-l:%M %p"),
      }
    }
  end

  # Bucket-start epochs, so the client can place a marker into its bucket on a
  # category axis. Nil in point mode (the time axis places markers directly).
  def buckets_ms
    return nil if bucket == :none

    bucket_starts.map { |start| start.to_i * 1000 }
  end

  # --- Buckets / range ---

  def bucket_key(time)
    time.public_send("beginning_of_#{bucket}")
  end

  def labels
    @labels ||= bucket_starts.map { |start| label_for(start) }
  end

  def bucket_starts
    @bucket_starts ||= build_bucket_starts
  end

  def build_bucket_starts
    span = range || full_span
    return [] if span.nil?

    start = span.first.public_send("beginning_of_#{bucket}")
    stop = span.last.public_send("beginning_of_#{bucket}")
    [].tap { |starts|
      current = start
      while current <= stop
        starts << current
        current = advance(current)
      end
    }
  end

  def advance(time)
    case bucket
    when :day  then time + 1.day
    when :week then time + 1.week
    when :month then time.next_month
    when :year  then time.next_year
    end
  end

  def label_for(time)
    case bucket
    when :day, :week then time.strftime("%-m/%-d/%y")
    when :month then time.strftime("%b %Y")
    when :year  then time.strftime("%Y")
    end
  end

  def range
    @range ||= resolve_range
  end

  def resolve_range
    if @override_start.present? && @override_end.present?
      return (parse_time(@override_start).beginning_of_day..parse_time(@override_end).end_of_day)
    end

    now = Time.current
    case (@override_range || @chart.range).to_s
    when "all" then nil
    when "ytd" then now.beginning_of_year..now.end_of_day
    when /\A(\d+)mo\z/ then ((now - Regexp.last_match(1).to_i.months).beginning_of_day..now.end_of_day)
    when /\A(\d+)w(?:k)?\z/ then ((now - Regexp.last_match(1).to_i.weeks).beginning_of_day..now.end_of_day)
    when /\A(\d+)d\z/  then ((now - Regexp.last_match(1).to_i.days).beginning_of_day..now.end_of_day)
    else (now - 12.months).beginning_of_day..now.end_of_day
    end
  end

  # Earliest..latest matched event, used when range is "all".
  def full_span
    times = all_events.map(&:timestamp)
    return nil if times.empty?

    times.min..times.max
  end

  def in_range?(time)
    range.nil? || range.cover?(time)
  end

  # The resolved window in epoch ms, so the client can shift prev/next by exactly
  # one span without re-deriving the range presets.
  def window_bounds
    span = range || full_span
    return nil if span.nil?

    { start: span.first.to_i * 1000, end: span.last.to_i * 1000 }
  end

  def range_label
    span = range || full_span
    return "All time" if range.nil? && span.nil?
    return "All time" if range.nil?

    "#{span.first.strftime("%b %-d, %Y")} – #{span.last.strftime("%b %-d, %Y")}"
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    Time.current
  end

  # Header tiles. `total`/`average` use the primary configured value; `count` is
  # always the number of matched events in range.
  def stats
    events = in_range_events
    return { count: 0, total: 0, average: 0 } if events.empty?

    values = events.map { |evt| value_for(evt) }
    {
      count:   events.length,
      total:   values.sum.round(2),
      average: (values.sum / values.length.to_f).round(2),
    }
  end
end
