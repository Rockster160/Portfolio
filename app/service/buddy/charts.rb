module Buddy
  # A chart drawn in the thread, from the same machinery as the Charts page.
  #
  # Buddy describes one the way the chart editor does - a search over logged
  # events and how to add them up - and it's built by CustomChart/ChartBuilder
  # exactly as a saved one would be. The message carries that description
  # alongside the drawn result, so the chart can be saved to the Charts page as
  # it stands, and opened there to be changed.
  module Charts
    module_function

    # What a chart in the thread is drawn from: the config, the query, and the
    # numbers it came to at the moment it was posted.
    META = "chart".freeze

    # The arguments a chart is described with, as the editor's own fields.
    CONFIG_KEYS = %i[
      value_source data_key series_key metric series_by bucket chart_type range unit queries marker_query colors
    ].freeze

    # One of their saved charts, by name. Exact first, then the closest
    # containing match, so "the check-in one" finds "Morning check-in".
    def saved(user, name)
      wanted = name.to_s.strip
      return nil if wanted.empty?

      charts = user.custom_charts.where(user: user).ordered.to_a
      charts.find { |chart| chart.name.to_s.casecmp?(wanted) } ||
        charts.find { |chart| CustomChart.normalize_label(chart.name).include?(CustomChart.normalize_label(wanted)) }
    end

    # An unsaved chart from a description. Raises on a value the editor
    # wouldn't offer, so a guessed option comes back as something to fix.
    def describe(user, name:, query:, **options)
      config = CustomChart::DEFAULTS.merge(options.slice(*CONFIG_KEYS).compact_blank)
      check!(config)
      user.custom_charts.new(name: name.to_s.presence || "Chart", query: query.to_s, config: config)
    end

    def check!(config)
      {
        value_source: CustomChart::VALUE_SOURCES,
        metric:       CustomChart::METRICS,
        series_by:    CustomChart::SERIES_BYS,
        bucket:       CustomChart::BUCKETS,
        chart_type:   CustomChart::CHART_TYPES,
      }.each { |key, allowed|
        next if allowed.include?(config[key].to_s.to_sym)

        raise "#{key} must be one of #{allowed.join(", ")}, not #{config[key].inspect}"
      }
      return unless config[:value_source].to_s == "data" && config[:data_key].blank?
      # Each key is its own line there, so it names its own.
      return if config[:series_by].to_s == "data_keys"

      raise "value_source data needs a data_key"
    end

    def post!(conversation:, user:, chart:, payload:)
      message = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         "📈 #{chart.name}",
        metadata:     {
          "kind"   => "buddy",
          "source" => "chart",
          META     => {
            "name"     => chart.name,
            "query"    => chart.query,
            "config"   => chart.config,
            "saved_id" => chart.id,
            "payload"  => payload.as_json,
          },
        },
        delivered_at: Time.current,
      )
      Buddy::ActivityChip.broadcast(user, message)
      message
    end

    # Saves the chart a message is drawing onto the Charts page, once, and
    # stamps the message so it shows it's saved from then on.
    def save!(user, message)
      drawn = message.metadata.to_h[META]
      raise ActiveRecord::RecordNotFound, "that message has no chart" if drawn.blank?

      existing = user.custom_charts.find_by(id: drawn["saved_id"]) if drawn["saved_id"]
      return existing if existing

      chart = user.custom_charts.create!(name: drawn["name"], query: drawn["query"], config: drawn["config"])
      message.update!(metadata: message.metadata.merge(META => drawn.merge("saved_id" => chart.id)))
      chart
    end

    # What the model is told about the chart it drew, so it can talk about the
    # numbers rather than describe a picture it hasn't seen.
    def summary(payload)
      {
        range:   payload[:range_label],
        error:   payload[:error],
        totals:  payload[:stats],
        series:  Array(payload[:datasets]).map { |set| series_summary(set) },
        markers: Array(payload[:markers]).group_by { |mark| mark[:name] }.transform_values(&:count).presence,
      }.compact
    end

    def series_summary(set)
      values = Array(set[:data]).filter_map { |point| point.is_a?(Hash) ? point[:y] || point["y"] : point }
      values = values.select { |value| value.is_a?(Numeric) }
      return { label: set[:label], points: 0 } if values.empty?

      {
        label:   set[:label],
        points:  values.length,
        average: (values.sum / values.length.to_f).round(2),
        low:     values.min,
        high:    values.max,
        latest:  values.last,
      }
    end
  end
end
