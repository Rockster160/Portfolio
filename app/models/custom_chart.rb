# == Schema Information
#
# Table name: custom_charts
#
#  id         :bigint           not null, primary key
#  config     :jsonb            not null
#  name       :text
#  position   :integer
#  query      :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class CustomChart < ApplicationRecord
  belongs_to :user

  validates :name, presence: true

  search_terms :id, :name

  scope :ordered, -> { order(Arel.sql("position IS NULL"), :position, :id) }

  # Enumerations for the chart-shape config. Stored (as strings) in the jsonb
  # `config` column, so adding an option here never needs a migration.
  VALUE_SOURCES = [:count, :notes, :data].freeze  # :data pairs with data_key
  METRICS       = [:count, :sum, :avg, :min, :max, :gap].freeze
  # :data_keys splits on the KEYS present in data; :data_value splits on the
  # VALUE of one key (series_key), so a jsonb field that holds a label —
  # category, source, status — becomes one series per distinct label.
  SERIES_BYS    = [:none, :name, :notes, :data_keys, :data_value, :sign].freeze
  BUCKETS       = [:none, :day, :week, :month, :year].freeze
  CHART_TYPES   = [:bar, :line, :stacked_bar].freeze

  DEFAULTS = {
    value_source: :count,
    data_key:     nil,
    series_key:   nil,
    metric:       :count,
    series_by:    :none,
    bucket:       :month,
    chart_type:   :bar,
    range:        "12mo",
    unit:         "",
    queries:      "",
    marker_query: "",
    colors:       "",
    colors_task:  "",
    invert_sign:  false,
  }.freeze

  # A symbolized, default-filled view of the jsonb config.
  def settings
    DEFAULTS.merge((config || {}).symbolize_keys.transform_keys(&:to_sym)).tap { |s|
      %i[value_source metric series_by bucket chart_type].each { |k| s[k] = s[k].to_sym if s[k].present? }
    }
  end

  def value_source = settings[:value_source]
  def data_key     = settings[:data_key].presence
  # Which data key a :data_value series splits on. Separate from data_key,
  # which names the key the VALUE is read from — a spend chart sums `amount`
  # while splitting on `category`.
  def series_key   = settings[:series_key].presence
  def metric       = settings[:metric]
  def series_by    = settings[:series_by]
  def bucket       = settings[:bucket]
  def chart_type   = settings[:chart_type]
  def range        = settings[:range].to_s
  def unit         = settings[:unit].to_s
  def marker_query = settings[:marker_query].to_s

  # Flips the polarity of every value the chart reads, so a source that stores
  # the thing you care about as negative (spend positive / deposits negative,
  # weight lost as a negative delta) reads the way you think about it. Applies
  # once at the value, so series split, bar heights, tooltip labels and the
  # total/average headline all agree.
  def invert_sign = ::ActiveModel::Type::Boolean.new.cast(settings[:invert_sign])

  # Name of a Jil `function()::Hash` task returning { "Series label" => "#hex" }.
  # Lets a chart whose series come from a maintained vocabulary follow that
  # vocabulary instead of holding a copy — see the spending categories, where
  # the list lives in ::TransactionCategory and a hand-kept color map is how a
  # category ends up rendering uncolored.
  def colors_task = settings[:colors_task].to_s.presence

  # Per-series color overrides, matched against dataset labels. Works across
  # every series mode (query, name, data key, sign) since it keys on the
  # visible label.
  #
  # Two sources, and the literal lines win: a task supplies the maintained
  # baseline, and the textarea stays a per-chart override for the one series
  # you want different here.
  #
  # Memoized because ChartBuilder reads this once PER DATASET — without it a
  # 22-series chart would run the Jil task 22 times to render once.
  def colors
    @colors ||= task_colors.merge(literal_colors)
  end

  def literal_colors
    settings[:colors].to_s.lines.each_with_object({}) { |line, map|
      line = line.strip
      next if line.blank? || line.exclude?("=")

      label, hex = line.split("=", 2).map(&:strip)
      map[label] = hex if label.present? && hex.present?
    }
  end

  # Colors are cosmetic and ChartBuilder already falls back to its palette, so
  # a missing or broken task must not take the chart down with it.
  def task_colors
    return {} if colors_task.blank?

    # `by_method_name` compares against the name with every non-word character
    # stripped, so "Transaction Category Colors" is looked up as
    # "TransactionCategoryColors". Normalize here so the field accepts the
    # readable name as typed.
    task = user.tasks.active.enabled.functions.by_method_name(colors_task.gsub(/\W+/, "")).take
    return {} if task.blank?

    result = task.execute({}, auth: :exec, trigger_scope: :exec)&.result
    return {} unless result.is_a?(::Hash)

    result.each_with_object({}) { |(label, hex), map|
      map[label.to_s] = hex.to_s if label.present? && hex.present?
    }
  rescue ::StandardError => e
    ::Rails.logger.warn("[CustomChart##{id}] colors_task #{colors_task.inspect} failed: #{e.message}")
    {}
  end

  # Multi-series from several queries, authored one-per-line as "Label = query"
  # (or just "query"). When present, each becomes its own series and overrides
  # the single filter + series_by. Modifiers (any order at the start of a line):
  #   - "[group]" assigns a stack group — series sharing a group stack into one
  #     bar; different groups sit side by side per bucket
  #   - a leading "-" negates the series (renders below zero — e.g. burn)
  #   - a query of "@daily N" is a synthetic flat series worth N per day (e.g. RMR)
  def queries
    settings[:queries].to_s.lines.filter_map { |line|
      line = line.strip
      next if line.blank?

      group = line[/\A\[([^\]]+)\]/, 1]
      line = line.sub(/\A\[[^\]]+\]\s*/, "") if group

      negate = line.start_with?("-")
      line = line.sub(/\A-\s*/, "") if negate
      label, spec = (line.include?("=") ? line.split("=", 2).map(&:strip) : [line, line])
      next if spec.blank?

      daily = spec[/\A@daily\s+(-?\d+(?:\.\d+)?)\z/, 1]
      {
        label:  label.presence || spec,
        query:  (daily ? nil : spec),
        negate: negate,
        daily:  daily&.to_f,
        group:  group&.strip,
      }
    }
  end

  # Builds the Chart.js-ready payload. `overrides` (e.g. start:, end:, bucket:)
  # let the show page tweak scope on the fly without changing the saved config.
  def build(overrides={})
    ChartBuilder.new(self, **overrides).call
  end
end
