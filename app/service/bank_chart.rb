# Money over time for whatever the banking page's search matched: one series
# per category, bucketed by day/week/month/year.
#
# The shape is CustomChart 4's ("Transactions"), and deliberately so — the same
# reading should mean the same thing wherever it appears. What it cannot be is
# that chart: `ChartBuilder` aggregates `action_events`, and half of these rows
# have no event behind them. Reading the transactions table is the entire point
# of the table existing.
#
# What it borrows from `ChartBuilder#series_by_data_value`, and must keep
# borrowing, is the two-stack rule: money out and money in each get their own
# stack so they stand SIDE BY SIDE per bucket rather than one column crossing
# zero — where the halves can only be compared by carrying your eye across the
# axis and neither reads as a whole. Both are plotted as magnitudes on one
# shared upward scale; never a second or mirrored y-axis.
class BankChart
  BUCKETS = %i[day week month year].freeze
  DEFAULT_BUCKET = :month

  # Past this the axis is unreadable and the payload is pointless — 3,650 daily
  # columns in 900px is a smear. It refuses and says so rather than quietly
  # coarsening the bucket, which would answer a question nobody asked.
  MAX_BUCKETS = 400

  # A category's stack, decided ONCE from its total across the whole window
  # rather than per bucket — otherwise a month holding a single refund would
  # move "groceries" to the income side for that column alone, and the series
  # would appear in both stacks of the same chart.
  OUT = "out".freeze
  IN = "in".freeze

  NO_CATEGORY = "(none)".freeze

  def initialize(scope, bucket: nil, from: nil, to: nil)
    @scope = scope
    @bucket = bucket.to_s.presence&.to_sym
    @bucket = DEFAULT_BUCKET unless BUCKETS.include?(@bucket)
    @from = from
    @to = to
  end

  def call
    ::User.timezone {
      next empty_payload if rows.empty?
      next too_many_payload if starts.length > MAX_BUCKETS

      {
        labels:   starts.map { |start| label_for(start) },
        datasets: datasets,
        bucket:   @bucket,
        unit:     "$",
      }
    }
  end

  private

  # Three columns, not records. The chart needs every matching row while the
  # table below shows a hundred, so instantiating them would be the most
  # expensive thing on the page for no use — nothing here calls a method on a
  # transaction.
  def rows
    @rows ||= @scope.reorder(nil).pluck(:occurred_at, :category, :amount_cents)
  end

  # Summed per (category, bucket) in cents, then converted once at the end.
  # Rounding dollars per row and adding those up drifts.
  def totals
    @totals ||= rows.each_with_object(Hash.new(0)) { |(at, category, cents), acc|
      next if at.blank?

      acc[[category.presence || NO_CATEGORY, bucket_key(at)]] += cents.to_i
    }
  end

  def category_totals
    @category_totals ||= totals.each_with_object(Hash.new(0)) { |((category, _start), cents), acc|
      acc[category] += cents
    }
  end

  # Biggest first, so the leading position in each stack belongs to the series
  # that dominates it rather than to whichever category sorted first.
  def datasets
    ordered = category_totals.sort_by { |_category, cents| -cents.abs }

    ordered.map { |category, total|
      {
        label: label_for_category(category),
        color: ::TransactionCategory.color(category),
        stack: (total.negative? ? OUT : IN),
        data:  starts.map { |start| ((totals[[category, start]] || 0).abs / 100.0).round(2) },
      }
    }
  end

  def label_for_category(category)
    return NO_CATEGORY if category == NO_CATEGORY

    ::TransactionCategory.label(category)
  end

  def bucket_key(at)
    at.in_time_zone(::User.timezone).public_send("beginning_of_#{@bucket}")
  end

  # Every bucket between the ends, including the ones nothing landed in — a
  # month with no spending is a fact about the month, and dropping it would put
  # two non-adjacent columns side by side and make the gap invisible.
  #
  # Spans the dates the SEARCH names where it names them, and the data
  # otherwise: asking for a year and seeing an axis that stops at the last
  # purchase hides that the rest of the year is empty.
  def starts
    @starts ||= build_starts
  end

  def build_starts
    keys = totals.keys.map(&:last)
    first = [(bucket_key(@from) if @from), keys.min].compact.min
    last = [(bucket_key(@to) if @to), keys.max].compact.max
    return [] if first.nil? || last.nil?

    [].tap { |list|
      current = first
      while current <= last && list.length <= MAX_BUCKETS
        list << current
        current = advance(current)
      end
    }
  end

  def advance(start)
    case @bucket
    when :day then start + 1.day
    when :week then start + 1.week
    when :month then start.next_month
    else start.next_year
    end
  end

  # The year is carried only when the span needs it. "Aug 17" twice on one axis
  # is two different days a year apart, and there is nothing on the chart to
  # say which is which; on a one-month view the same year on every tick is
  # noise.
  def label_for(start)
    case @bucket
    when :day, :week then start.strftime(spans_years? ? "%b %-d, %Y" : "%b %-d")
    when :month then start.strftime("%b %Y")
    else start.strftime("%Y")
    end
  end

  def spans_years?
    return @spans_years if defined?(@spans_years)

    @spans_years = starts.map(&:year).uniq.many?
  end

  def empty_payload
    { labels: [], datasets: [], bucket: @bucket, unit: "$", message: "Nothing to chart." }
  end

  def too_many_payload
    {
      labels:   [],
      datasets: [],
      bucket:   @bucket,
      unit:     "$",
      message:  "Over #{MAX_BUCKETS} #{@bucket}s in range — " \
                "pick a bigger bucket or narrow the dates.",
    }
  end
end
