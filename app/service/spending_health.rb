# Feeds the dashboard's Spending cell: how much of the month's money is left,
# on three nested clocks — the month, the week (Monday to Sunday), and today.
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
  MONTHLY_CENTS = 400_000
  # A purchase ABOVE this is a large one: rent-sized, tuition-sized, a flight.
  # One of those lands on a single day and would read as that day and that week
  # being blown, when it was planned money. So they are bucketed apart — the
  # bars never draw them, and the cell takes the month's large purchases off
  # the month's budget instead, which lowers every day of it evenly.
  LARGE_CENTS = 50_000
  # The top bar: everything there is, against what it is meant to hold, over
  # the stretch it has to last. From the layoff to the end of the year. `from`
  # and `through` are both whole perceived days, so the range runs from 3am on
  # the first to 3am after the last.
  BALANCE_GOAL = {
    cents:   4_000_000,
    from:    "2026-09-11",
    through: "2026-12-31",
  }.freeze
  # How far back the buckets reach beyond the start of the month. The week can
  # begin on a Monday in the previous one.
  LOOKBACK_DAYS = 7

  class << self
    def refresh!(user: ::User.me)
      data = payload(user)
      previous = user.caches.get(CACHE_KEY)
      user.caches.dig_set(CACHE_KEY, data)

      publish!(user) if previous.as_json != data.as_json

      data
    end

    # Cents spent per perceived day, with the large purchases in buckets of
    # their own, plus the budget those days are measured against. Dates are ISO
    # strings because that is what survives the trip through JSON and back out
    # to the cell.
    #
    # The large ones are dated rather than totalled for the same reason the
    # rest are: at the turn of the month last month's rent has to stop coming
    # off the budget, with nothing pushed to say so.
    #
    # The balance is the home cell's figure — cumulative and projected, see
    # SimpleFin::DashboardCache — and nil when an account has none yet, which
    # the cell draws as nothing rather than as a smaller total.
    #
    # The day's caffeine rides along: it is the bottom bar of the same cell,
    # and one cell wants one payload and one broadcast rather than a second
    # channel that can arrive out of step with this one.
    def payload(user)
      {
        budget_cents:  MONTHLY_CENTS,
        balance_cents: ::SimpleFin::DashboardCache.projected_cents,
        balance_goal:  BALANCE_GOAL,
      }.merge(
        buckets(user),
        ::CaffeineIntake.payload(user),
      )
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
      pairs = scope.pluck(:occurred_at, :amount_cents)
      pairs.each_with_object({ days: {}, large_days: {} }) { |(at, cents), acc|
        into = acc[cents.abs > LARGE_CENTS ? :large_days : :days]
        key = ::Buddy::Day.perceived_date(at.in_time_zone(zone)).to_s
        into[key] = into.fetch(key, 0) + cents.abs
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
