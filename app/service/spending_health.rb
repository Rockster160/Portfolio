# Feeds the dashboard's Spending cell: how much of the month's money is left,
# on three nested clocks — the month, the trailing week, and today.
#
# It publishes DAILY BUCKETS rather than the three totals it is asked for,
# because the totals are the one thing that can go stale with nothing having
# happened. A total is wrong the moment the perceived day rolls over at 3am,
# and nothing writes to bank_transactions to say so — there is no record change
# to hang a refresh off. Buckets are dated, so the cell sums them against its
# own clock and a page left open overnight lands on the right day by itself.
#
# It also means a stale cache is still a CORRECT cache: a day nobody spent on
# has no bucket, and a missing bucket reads as zero, which is what it was.
#
# Same publish route as SimpleFin::DashboardCache — write the key, trigger the
# Jil task that owns the cell — so what the dashboard displays stays editable
# without a deploy.
module SpendingHealth
  CACHE_KEY = :spending
  # What a month's spending is measured against. Not derived from anything: it
  # is the number the household picked. The day and week budgets come off it —
  # a day is the month split evenly, a week is seven of those — so a 31-day
  # month gets a slightly smaller daily allowance than a 30-day one, which is
  # the point of dividing rather than fixing a number.
  MONTHLY_CENTS = 800_000
  # How far back the buckets reach beyond the start of the month. The trailing
  # week can begin in the previous one, and on the 1st it lies entirely there.
  LOOKBACK_DAYS = 7

  class << self
    def refresh!(user: ::User.me)
      data = payload(user)
      previous = user.caches.get(CACHE_KEY)
      user.caches.dig_set(CACHE_KEY, data)

      publish!(user) if previous.as_json != data.as_json

      data
    end

    # Cents spent per perceived day, plus the budget those days are measured
    # against. Dates are ISO strings because that is what survives the trip
    # through JSON and back out to the cell.
    def payload(user)
      { budget_cents: MONTHLY_CENTS, days: buckets(user) }
    end

    # Grouped in Ruby rather than SQL: a perceived day is local-3am to
    # local-3am, so grouping in Postgres means an AT TIME ZONE dance around a
    # column that carries no zone, and it is ~150 rows a month.
    def buckets(user)
      zone = ::Buddy::Day.zone(user)
      today = ::Buddy::Day.today(user)
      from = ::Buddy::Day.range(user, date: today.beginning_of_month - LOOKBACK_DAYS).first
      to = ::Buddy::Day.range(user, date: today).last

      scope = ::BankTransaction.countable.spending.where(occurred_at: from...to)
      scope.pluck(:occurred_at, :amount_cents).each_with_object({}) { |(at, cents), acc|
        key = ::Buddy::Day.perceived_date(at.in_time_zone(zone)).to_s
        acc[key] = acc.fetch(key, 0) + cents.abs
      }
    end

    # Writing the cache key moves nothing on screen by itself — the Jil task
    # listening on `monitor:spending` is what reads it and broadcasts, so
    # without this the cell only picks up a new figure the next time the
    # dashboard asks for the channel.
    #
    # `auth:` is passed explicitly so the data hash is not the trailing
    # argument; a bare trailing hash there is read as keyword arguments.
    def publish!(user)
      ::Jil.trigger(user, :monitor, { channel: :spending, refresh: true }, auth: :trigger)
    rescue ::StandardError => e
      # The buckets are already stored and correct. A task that fails while
      # re-rendering the cell must not take a sync — or the alert that produced
      # it — down with it.
      ::Rails.logger.warn("[SpendingHealth] spending refresh failed: #{e.message}")
    end
  end
end
