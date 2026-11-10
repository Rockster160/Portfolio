Buddy::Tools.register(
  name:        :show_chart,
  summary:     "Draw a chart of their logged events in the thread - one of their saved charts, " \
               "or a new one over any search, range and grouping. It can be saved from there.",
  description: <<~TXT,
    Draw a chart of the person's logged events in this conversation, the same
    kind of chart their Charts page draws. Use it when they want to SEE
    something over time - "graph my feelings this month", "chart caffeine by
    week", "show my check-in chart" - and when a trend is easier to show than
    to say. The chart lands just above your reply, with a button that saves it
    to their Charts page, so a good one they can keep.

    You get its numbers back - each line's average, low, high and latest - so
    say what it shows in a line or two. The picture is already there.

    ## One of their saved charts

    `saved` is the name of one of their charts. `range` and `bucket` still
    change the window and the grouping; everything else comes from the chart.

    ## A new one

    `query` picks the events, in the app's search syntax: `name::Coffee` is
    exactly that name, `name:coffee` contains it, `OR` between alternatives,
    quotes around anything with a space, and `timestamp>2026-07-01` to bound
    it. It's already only theirs.

    What each event is worth (`value_source`):
      count  - one per event (the default)
      notes  - the number in the notes
      data   - the number under `data_key` in the event's data

    `metric` adds them up per bucket: count, sum, avg, min, max, or gap (days
    between events). A rating is avg; an amount is sum.

    `series_by` splits it into several lines: name (one per event name),
    data_keys (one per number in the event's data - every slider on a survey
    as its own line), data_value (one per value of `series_key`), notes, sign.
    `queries` instead gives one line per search, one per line as
    `Label = query`.

    `marker_query` draws a dashed upright line at each event it matches - the
    days something happened, against the lines. Each event name gets its own
    color, and `colors` sets them, one per line as `Label = #hex`, for series
    and markers alike.

    `bucket`: none (every event as a point), day, week, month, year.
    `range`: how far back - 7d, 30d, 3mo, 12mo, 2y, all.
    `chart_type`: line, bar, stacked_bar. A rating over time is a line.

    Look up what the events are called and what their data holds before
    drawing a new one, so the search matches something.
  TXT
  feature:     :events,
  args:        {
    saved:        { type: :string, required: false, description: "One of their saved charts, by name" },
    name:         { type: :string, required: false, description: "Title for a new chart" },
    query:        { type: :string, required: false, description: "Which events, in search syntax" },
    value_source: { type: :enum, required: false, values: %i[count notes data], description: "What each event is worth" },
    data_key:     { type: :string, required: false, description: "The data key to read, with value_source data" },
    series_key:   { type: :string, required: false, description: "The data key to split on, with series_by data_value" },
    metric:       { type: :enum, required: false, values: %i[count sum avg min max gap], description: "How a bucket adds up" },
    series_by:    { type: :enum, required: false, values: %i[none name notes data_keys data_value sign], description: "What splits it into lines" },
    queries:      { type: :string, required: false, description: "One line per search, as `Label = query` per line" },
    marker_query: { type: :string, required: false, description: "Events drawn as upright marker lines" },
    colors:       { type: :string, required: false, description: "`Label = #hex` per line" },
    bucket:       { type: :enum, required: false, values: %i[none day week month year], description: "Grouping" },
    range:        { type: :string, required: false, description: "How far back: 7d, 30d, 3mo, 12mo, 2y, all" },
    chart_type:   { type: :enum, required: false, values: %i[line bar stacked_bar], description: "How it's drawn" },
    unit:         { type: :string, required: false, description: "A unit for the numbers, like $" },
  },
  auto:        true,
  answers:     true,
  acts:        true,
  # A chart is drawn from whatever is logged when it's asked for. Scheduling
  # one would draw it from that day's data, which a reminder can do just as
  # well by asking.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    if payload[:saved].present?
      chart = Buddy::Charts.saved(ctx.user, payload[:saved])
      raise "no saved chart called #{payload[:saved].inspect}" if chart.nil?

      next { summary: "Show #{chart.name}", resolved: { chart_id: chart.id, title: chart.name } }
    end

    raise "a new chart needs a query or queries" if payload[:query].blank? && payload[:queries].blank?

    options = payload.slice(*Buddy::Charts::CONFIG_KEYS)
    chart   = Buddy::Charts.describe(ctx.user, name: payload[:name], query: payload[:query], **options)
    { summary: "Chart #{chart.name}", resolved: { title: chart.name } }
  },
  label:       ->(payload, _ctx) { "📈 #{payload[:title] || payload[:name] || "Chart"}" },
  execute:     ->(payload, ctx) {
    chart = (
      if payload[:chart_id]
        ctx.user.custom_charts.find(payload[:chart_id])
      else
        options = payload.slice(*Buddy::Charts::CONFIG_KEYS)
        Buddy::Charts.describe(ctx.user, name: payload[:name], query: payload[:query], **options)
      end
    )
    overrides = payload.slice(:range, :bucket).compact_blank
    built     = chart.build(overrides).deep_symbolize_keys
    if overrides.any? && chart.persisted?
      chart = chart.dup
      chart.config = chart.config.merge(overrides.stringify_keys)
    end

    Buddy::Charts.post!(conversation: ctx.conversation, user: ctx.user, chart: chart, payload: built)
    Buddy::Charts.summary(built).merge(
      how: "The chart is in the thread just above your reply. Say what it shows in a line or two.",
    )
  },
)
