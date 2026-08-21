module Buddy
  # Hands the spooled local spend to production.
  #
  # Nothing here reaches into another database: it is an ordinary authenticated
  # POST to the same API the rest of the laptop already uses, and the far end
  # decides what is new. That is why the spool is only archived once every batch
  # has landed — a re-send of a file that half-arrived costs one request and
  # changes nothing, while a file filed away as done is spend nobody can get
  # back.
  module UsageSync
    module_function

    class Error < StandardError; end

    # Small enough that a failure re-sends little, large enough that a month of
    # evals is a handful of requests.
    BATCH = 200
    PATH  = :buddy_usages

    def call(batch: BATCH)
      rows = UsageSpool.pending
      return { rows: 0, created: 0, duplicate: 0, skipped: 0 } if rows.empty?

      counts = Hash.new(0)
      rows.each_slice(batch).with_index(1) { |slice, index|
        data = deliver(slice)
        %i[received created duplicate skipped].each { |key| counts[key] += data[key].to_i }
        yield(index, data) if block_given?
      }

      counts.merge(rows: rows.length, archived: UsageSpool.archive!(stamp))
    end

    def deliver(slice)
      result = ProdApi.post(PATH, { usages: slice }, content_type: "application/json")
      data   = result.is_a?(Hash) ? (result[:data] || result) : {}
      raise Error, "unexpected response: #{result.inspect}" if data[:received].nil?

      data
    end

    # Rows this database wrote before there was anywhere to send them, or while
    # the spool file was somewhere else. Skips anything already written down, so
    # running it twice sends one afternoon once.
    #
    # `from_development` is what keeps a restored backup out of it. Development
    # here is a copy of production, so most of the rows in it were spent by
    # production and are already counted there; only the ones this machine wrote
    # since the restore say `development`. `unsynced` catches the other half of
    # the same problem — a row that went to production and came back in a later
    # backup arrives carrying the uid it was filed under.
    def backfill!(days: nil)
      scope = BuddyUsage.from_development.unsynced
      scope = scope.since(days.to_i.days.ago) if days.present?

      already = UsageSpool.spooled_uids
      rows    = scope.chronological.reject { |row| already.include?(UsageSpool.uid_for(row)) }
      rows.each { |row| UsageSpool.write(UsageSpool.line(row)) }
      rows
    end

    def stamp
      Time.current.strftime("%Y%m%d%H%M%S")
    end
  end
end
