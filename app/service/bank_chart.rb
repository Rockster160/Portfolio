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

  # Each row lands in the stack its own sign says, so a category can have a
  # series in both: groceries spent on the out side, a groceries refund on the
  # in side. Deciding one stack per category from its net instead drew every
  # bucket that went the other way on the wrong side — a month of lease
  # payments shown as $450 of income because refunds elsewhere in the range
  # left uncategorized rows net positive. Split this way, each stack's height
  # is the same gross figure the page's spend and income totals report.
  OUT = "out".freeze
  IN = "in".freeze

  NO_CATEGORY = "(none)".freeze

  # `base_query` is the search with its category, direction and date terms
  # taken out. Clicking a segment adds those three back for that segment, so it
  # rides in the payload rather than being rebuilt by a regex in the browser.
  def initialize(scope, bucket: nil, from: nil, to: nil, base_query: nil)
    @scope = scope
    @base_query = base_query.to_s
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
        labels:     starts.map { |start| label_for(start) },
        ranges:     starts.map { |start| range_for(start) },
        datasets:   datasets,
        balance:    balance,
        bucket:     @bucket,
        unit:       "$",
        base_query: @base_query,
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

  # Summed per (category, stack, bucket) in cents, then converted once at the
  # end. Rounding dollars per row and adding those up drifts.
  def totals
    @totals ||= rows.each_with_object(Hash.new(0)) { |(at, category, cents), acc|
      next if at.blank? || cents.to_i.zero?

      stack = (cents.to_i.negative? ? OUT : IN)
      acc[[category.presence || NO_CATEGORY, stack, bucket_key(at)]] += cents.to_i.abs
    }
  end

  def series_totals
    @series_totals ||= totals.each_with_object(Hash.new(0)) { |(key, cents), acc|
      acc[key.first(2)] += cents
    }
  end

  # Biggest first, so the leading position in each stack belongs to the series
  # that dominates it rather than to whichever category sorted first.
  #
  # `category` is what the search calls this series, and `stack` doubles as
  # its `direction:`, for the click that lists its rows.
  def datasets
    ordered = series_totals.sort_by { |_series, cents| -cents }

    ordered.map { |(category, stack), _total|
      {
        label:    label_for_category(category),
        color:    ::TransactionCategory.color(category),
        stack:    stack,
        category: (category == NO_CATEGORY ? "none" : category),
        data:     starts.map { |start| ((totals[[category, stack, start]] || 0) / 100.0).round(2) },
      }
    }
  end

  # First and last day of a bucket, as the search's `timestamp>=` and
  # `timestamp<=` take them — both inclusive.
  def range_for(start)
    [start.to_date.iso8601, (advance(start) - 1.day).to_date.iso8601]
  end

  # The dashboard figure as each bucket opened. Not the search's rows: it is
  # the whole balance whatever the search narrowed to, so a "groceries" view
  # still shows what there was to spend it from.
  def balance
    ::BankTotalSnapshot.opening_cents_at(starts).map { |cents|
      (cents / 100.0).round(2) unless cents.nil?
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
