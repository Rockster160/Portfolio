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
  SERIES_BYS    = [:none, :name, :notes, :data_keys, :sign].freeze
  BUCKETS       = [:none, :day, :week, :month, :year].freeze
  CHART_TYPES   = [:bar, :line, :stacked_bar].freeze

  DEFAULTS = {
    value_source: :count,
    data_key:     nil,
    metric:       :count,
    series_by:    :none,
    bucket:       :month,
    chart_type:   :bar,
    range:        "12mo",
    unit:         "",
    queries:      "",
    marker_query: "",
    colors:       "",
  }.freeze

  # A symbolized, default-filled view of the jsonb config.
  def settings
    DEFAULTS.merge((config || {}).symbolize_keys.transform_keys(&:to_sym)).tap { |s|
      %i[value_source metric series_by bucket chart_type].each { |k| s[k] = s[k].to_sym if s[k].present? }
    }
  end

  def value_source = settings[:value_source]
  def data_key     = settings[:data_key].presence
  def metric       = settings[:metric]
  def series_by    = settings[:series_by]
  def bucket       = settings[:bucket]
  def chart_type   = settings[:chart_type]
  def range        = settings[:range].to_s
  def unit         = settings[:unit].to_s
  def marker_query = settings[:marker_query].to_s

  # Per-series color overrides, one per line as "Series label = #hex", matched
  # against dataset labels. Works across every series mode (query, name, data key,
  # sign) since it keys on the visible label.
  def colors
    settings[:colors].to_s.lines.each_with_object({}) { |line, map|
      line = line.strip
      next if line.blank? || line.exclude?("=")

      label, hex = line.split("=", 2).map(&:strip)
      map[label] = hex if label.present? && hex.present?
    }
  end

  # Multi-series from several queries, authored one-per-line as "Label = query"
  # (or just "query"). When present, each becomes its own series and overrides
  # the single filter + series_by. Two modifiers:
  #   - a leading "-" negates the series (renders below zero — e.g. burn)
  #   - a query of "@daily N" is a synthetic flat series worth N per day (e.g. RMR)
  def queries
    settings[:queries].to_s.lines.filter_map { |line|
      line = line.strip
      next if line.blank?

      negate = line.start_with?("-")
      line = line.sub(/\A-\s*/, "") if negate
      label, spec = (line.include?("=") ? line.split("=", 2).map(&:strip) : [line, line])
      next if spec.blank?

      daily = spec[/\A@daily\s+(-?\d+(?:\.\d+)?)\z/, 1]
      { label: label.presence || spec, query: (daily ? nil : spec), negate: negate, daily: daily&.to_f }
    }
  end

  # Builds the Chart.js-ready payload. `overrides` (e.g. start:, end:, bucket:)
  # let the show page tweak scope on the fly without changing the saved config.
  def build(overrides={})
    ChartBuilder.new(self, **overrides).call
  end
end
