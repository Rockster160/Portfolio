# Feeds the Caffeine bar at the bottom of the dashboard's Spending cell. It
# rides the spending cache and the spending broadcast — one cell, one payload —
# so nothing here publishes; SpendingHealth merges this in and does that.
#
# Like the money above it, what is published is DAILY BUCKETS rather than the
# day's total. A total is wrong the moment the perceived day rolls over at 3am
# and nothing writes to action_events to say the day changed, so there is no
# record change to hang a refresh off. Buckets are dated: the cell picks its own
# day out of them against the browser's clock, and a stale cache is still a
# CORRECT cache, because a day with no drinks on it has no bucket and a missing
# bucket reads as zero — which is what it was.
module CaffeineIntake
  # What the day's milligrams are measured against. The standard daily
  # guidance, and about where a heavy day already lands — two Celsius and a
  # soda clears it.
  DAILY_LIMIT_MG = 400
  # Milligrams live on the event's `data`, written by whatever logged the
  # drink. The KEY is what makes an event caffeine, not the event's NAME:
  # "Drink" is what they happen to be called today, and a coffee logged under
  # any other name still counts if it says how much it carried.
  DATA_KEY = "Caffeine".freeze
  # How far back the buckets reach. Only the perceived today is ever read, but
  # a payload built at 2:59am is read at 3:01am against a date that has since
  # moved on — yesterday costs one more day of rows and keeps that answer right
  # until the resync lands.
  LOOKBACK_DAYS = 1

  class << self
    def payload(user)
      { caffeine_limit_mg: DAILY_LIMIT_MG, caffeine: buckets(user) }
    end

    # Grouped in Ruby rather than SQL for the same reason the money buckets
    # are: a perceived day is local-3am to local-3am, so grouping in Postgres
    # means an AT TIME ZONE dance around a column that carries no zone, and it
    # is a handful of rows.
    def buckets(user)
      zone = ::Buddy::Day.zone(user)
      today = ::Buddy::Day.today(user)
      from = ::Buddy::Day.range(user, date: today - LOOKBACK_DAYS).first
      to = ::Buddy::Day.range(user, date: today).last

      scope = user.action_events.where(timestamp: from...to)
      scope = scope.where("(data->>:key) IS NOT NULL", key: DATA_KEY)
      scope.pluck(:timestamp, :data).each_with_object({}) { |(at, data), acc|
        mg = data[DATA_KEY].to_i
        next if mg.zero?

        key = ::Buddy::Day.perceived_date(at.in_time_zone(zone)).to_s
        acc[key] = acc.fetch(key, 0) + mg
      }
    end

    # Whether this event moves the day's milligrams, and so needs the cell
    # redrawn. Includes an event that has just LOST its caffeine — a correction
    # from 200mg to nothing changes the bar exactly as much as the 200 did.
    def logged?(event)
      [event.data, *event.saved_changes["data"]].any? { |data|
        data.is_a?(::Hash) && data.key?(DATA_KEY)
      }
    end
  end
end
