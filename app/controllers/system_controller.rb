class SystemController < ApplicationController
  before_action :require_me

  # Buddy usage timestamps are UTC; spend is bucketed by local calendar day so a
  # late-night turn lands on the day it felt like, not the next UTC one.
  SPEND_ZONE = "America/Denver".freeze
  # A window of 1 means "last 24 hours, hour by hour"; the rest are rolling day windows.
  SPEND_WINDOWS = [1, 7, 30, 90].freeze
  SPEND_DEFAULT_DAYS = 30
  TRANSACTION_PAGE = 100
  MEMORY_PAGE = 200
  ANNOUNCEMENT_PAGE = 50
  # A `timestamp` term in the search, with its comparison operator. Longest
  # operators first, or `>=` would match as `>` and leave a stray `=` behind.
  # A negated term (`-timestamp:`) deliberately does not match: it names dates
  # to exclude, which is not a range and has no place in a from/to picker.
  TIMESTAMP_TERM = /(?:\A|\s)timestamp(>=|<=|>|<|::|:)(\S+)/i
  # A search value: quoted where it has to be, because half the category names
  # are two words and `category:eat out` parses as `category:eat` plus a stray
  # bare word.
  SEARCH_VALUE = /(?:"[^"]*"|'[^']*'|[^\s)]+)/
  # Dark-theme palette, assigned to users by spend rank.
  SPEND_PALETTE = %w[
    #5DADE2 #58D68D #F5B041 #AF7AC5 #EC7063 #48C9B0 #F7DC6F #5499C7
  ].freeze

  def index; end

  def gpt_spending
    @windows = SPEND_WINDOWS
    @days = params[:days].to_i
    @days = SPEND_DEFAULT_DAYS unless SPEND_WINDOWS.include?(@days)
    @hourly = @days == 1

    scope, grouped, @buckets, @labels, calls = @hourly ? hourly_spend : daily_spend
    @calls_per_bucket = @buckets.map { |bucket| calls[bucket] || 0 }

    @user_totals = grouped.each_with_object(Hash.new(0)) { |((_bucket, user_id), micros), totals|
      totals[user_id] += micros
    }.sort_by { |_user_id, micros| -micros }
    @user_ids = @user_totals.map(&:first)
    @users = User.where(id: @user_ids).index_by(&:id)

    @colors = @user_ids.each_with_index.to_h { |user_id, i| [user_id, SPEND_PALETTE[i % SPEND_PALETTE.length]] }
    @datasets = @user_ids.map { |user_id|
      {
        label: @users[user_id]&.first_name || "User ##{user_id}",
        color: @colors[user_id],
        data:  @buckets.map { |bucket| (grouped[[bucket, user_id]] || 0) / Buddy::GPT::Pricing::MICROS_PER_DOLLAR.to_f },
      }
    }
    @total_micros = grouped.values.sum
    @call_count = scope.count

    divisor = @hourly ? 24 : @days
    @avg_micros = divisor.positive? ? @total_micros / divisor : 0
    @total_label = @hourly ? "Total, last 24h" : "Total, last #{@days} days"
    @avg_label = @hourly ? "Per hour (avg)" : "Per day (avg)"
  end

  # Accounts and recent transactions from SimpleFIN. `kind` and
  # `friendly_name` are set here because nothing else can set them — SimpleFIN
  # reports no account type, and until a checking account is designated the
  # dashboard has no balance to show.
  def banking
    @accounts = ::BankAccount.order(:kind, :name)
    @unclassified = @accounts.select(&:unknown?)
    @dashboard_cents = ::SimpleFin::DashboardCache.balance_cents
    @dashboard_available = ::SimpleFin::DashboardCache.available_cents
    # Which account is holding the figure back, so the page names it rather
    # than reporting a cause that may not be the real one.
    @dashboard_missing = ::SimpleFin::DashboardCache.missing_balance
    @stray_categories = ::TransactionCategory.unknown_in_use
    # Collapsed the same way the listing is, so the count matches the rows the
    # `category:none` link it points at will actually show.
    @uncategorized_count = ::BankTransaction.without_transfer_mirror.uncategorized.count
    @backfill = ::SimpleFin::Backfill.progress

    @query = params[:q].to_s.strip
    # Built after @query, because each one is that query with this account
    # swapped in.
    @account_filters = account_filters
    # Collapsed before anything counts it, so the result count, the pagination
    # and the bulk button all agree with the rows actually on screen.
    scope = filtered_transactions.without_transfer_mirror

    # Totals and the chart run on real money only. A self-transfer is the same
    # money seen twice — counting it inflates BOTH spend and income by the same
    # amount, so a card payoff reads as if the purchase happened twice.
    real = scope.real_money
    @spend_cents = real.spending.sum(:amount_cents)
    @income_cents = real.income.sum(:amount_cents)
    @result_count = scope.count
    @transfer_count = scope.count - real.count
    @category_totals = category_totals(real)

    # The bucket is a way of LOOKING at the results, so it rides as its own
    # param. The dates are a filter, so they live in the query itself — read
    # out of it here to fill the pickers, written back into it by them.
    @bucket = ::BankChart::BUCKETS.detect { |unit| unit.to_s == params[:bucket].to_s }
    @bucket ||= ::BankChart::DEFAULT_BUCKET
    @date_from, @date_to = query_dates
    @chart_data = ::BankChart.new(real, bucket: @bucket, from: @date_from, to: @date_to).call
    @legend = legend_entries(real)

    listing = scope.includes(:bank_account, :action_event, transfer_counterpart: :bank_account)
    listing = listing.recent_first
    @transactions = listing.page(params[:page]).per(TRANSACTION_PAGE)
  end

  # One field, answered as JSON, exactly as a transaction row is. The accounts
  # edit in place, so a redirect would throw the whole page away to rename one
  # thing.
  def update_bank_account
    account = ::BankAccount.find(params[:id])
    changed = {}

    if params.key?(:friendly_name)
      account.update!(friendly_name: params[:friendly_name].to_s.strip.presence)
      # Blank means "no chosen name", and the row shows the placeholder rather
      # than echoing the institution name it already prints underneath.
      changed[:friendly_name] = account.friendly_name.to_s
      changed[:display_name] = account.display_name
    end

    if params.key?(:kind)
      kind = params[:kind].to_s
      # `update!` on an unknown enum value raises ArgumentError, which is a 500
      # and unparseable to the row's error handler. Answer it as a rejection.
      unless ::BankAccount.kinds.key?(kind)
        return render(
          json:   { error: "#{kind} is not an account kind." },
          status: :unprocessable_entity,
        )
      end

      account.update!(kind: kind)
      # The headline balance follows whichever account is currently checking,
      # so re-publish whenever a kind changes.
      ::SimpleFin::DashboardCache.refresh!
      changed[:kind] = account.kind
    end

    render(json: changed)
  end

  # One row, one field, answered as JSON so the row updates in place. A full
  # reload after every category pick would throw away scroll position on a
  # hundred-row table.
  def update_transaction
    transaction = ::BankTransaction.find(params[:id])
    changed = {}

    if params.key?(:category)
      unless transaction.apply_category(params[:category])
        return render(json: { error: category_error(transaction) }, status: :unprocessable_entity)
      end

      changed[:category] = transaction.category
      changed[:color] = ::TransactionCategory.color(transaction.category)
    end

    if params.key?(:memo)
      transaction.update!(memo: params[:memo].to_s.strip.presence)
      changed[:memo] = transaction.display_memo
      changed[:from_event] = transaction.memo_from_event?
    end

    render(json: changed)
  end

  # Applies one category across a checkbox selection, or across every row the
  # current search matched — which is the point of the search syntax being
  # here at all.
  def bulk_update_transactions
    category = ::TransactionCategory.cast(params[:category])
    if category.nil?
      return redirect_to(system_banking_path(q: params[:q]), alert: "Unknown category.")
    end

    @query = params[:q].to_s.strip
    scope = (
      if params[:apply_to_search].present?
        # The same collapse the listing applies, so "all N matching" touches
        # the N the button counted.
        filtered_transactions.without_transfer_mirror
      else
        ::BankTransaction.where(id: Array.wrap(params[:transaction_ids]))
      end
    )

    updated = 0
    # No ActionEventNotifier here on purpose: it fires a :event Jil trigger per
    # event, and a bulk recategorise of a whole search would stampede every
    # watch and automation listening for one. ActionEventNotifier exists so
    # bulk paths can opt out — this is one.
    scope.includes(:action_event).find_each { |transaction|
      updated += 1 if transaction.apply_category(category)
    }

    notice = "Categorised #{updated} as #{::TransactionCategory.label(category)}."
    redirect_to(system_banking_path(q: params[:q].presence), notice: notice)
  end

  # Everything a companion is holding about somebody, in one table.
  #
  # Deliberately NOT in Byte. Buddy's own surface is for talking to; curating
  # what it has kept — deleting a memory that landed wrong, dropping a severity
  # that reads too high, disarming a check-in — is administration, and putting
  # it in the chat would mean a companion that keeps offering to manage itself.
  def memories
    @kinds = BuddyMemory.kinds.keys
    @kind  = params[:kind].presence_in(@kinds)
    @tag   = params[:tag].to_s.strip.downcase.presence
    @query = params[:q].to_s.strip

    scope = BuddyMemory.includes(:user, :notes)
    scope = scope.where(kind: @kind) if @kind
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    scope = Buddy::MemorySearch.matching(scope, @query) if @query.present?
    scope = Buddy::MemorySearch.tagged(scope, [@tag]) if @tag

    @total = scope.count
    @memories = scope.order(Arel.sql("severity DESC, COALESCE(last_touched_at, created_at) DESC")).limit(MEMORY_PAGE)
    @users = User.where(id: BuddyMemory.distinct.pluck(:user_id)).index_by(&:id)
    @all_tags = BuddyMemory.pluck(:tags).flatten.compact.map(&:to_s).tally.sort_by { |t, n| [-n, t] }.first(30)
  end

  # One field at a time, answered as JSON so a row edits in place.
  def update_memory
    memory  = BuddyMemory.find(params[:id])
    changed = {}

    if params.key?(:severity)
      memory.severity = params[:severity].to_i.clamp(BuddyMemory::SEVERITY_RANGE.min, BuddyMemory::SEVERITY_RANGE.max)
      changed[:severity] = memory.severity
    end

    if params.key?(:content)
      memory.content = params[:content].to_s.strip.first(BuddyMemory::MAX_CONTENT)
      changed[:content] = memory.content
    end

    if params.key?(:tags)
      memory.tag_list = params[:tags].to_s.split(",")
      changed[:tags] = memory.tag_list
    end

    if params.key?(:kind) && BuddyMemory.kinds.key?(params[:kind].to_s)
      memory.kind = params[:kind].to_s
      changed[:kind] = memory.kind
    end

    # Disarming a check-in is the single most likely reason to open this page at
    # all, so it gets to be a plain field rather than a separate action.
    if params.key?(:check_in_at)
      memory.check_in_at = params[:check_in_at].presence && Time.zone.parse(params[:check_in_at])
      changed[:check_in_at] = memory.check_in_at&.iso8601
    end

    return render(json: { error: memory.errors.full_messages.to_sentence }, status: :unprocessable_entity) unless memory.save

    render(json: changed)
  end

  def destroy_memory
    BuddyMemory.find(params[:id]).destroy!
    redirect_to(system_memories_path(kind: params[:kind], q: params[:q], tag: params[:tag]), notice: "Deleted.")
  end

  # Notes to be worked into somebody's next Today briefing. Its own page rather
  # than a panel on the memories list: this one has a form, and a form on a page
  # whose job is reading a long list would end up being the loudest thing there.
  def announcements
    @announcements = BuddyAnnouncement.includes(:user).order(created_at: :desc).limit(ANNOUNCEMENT_PAGE)
    @users = companion_users
  end

  # Who can actually receive one. Having a Buddy conversation IS having a
  # companion — the same gate Buddy::CompanionRelay uses to decide whether
  # someone can be reached at all. There is no per-user flag for this; `tasks`
  # has a `buddy_enabled` column and it is about Jil task access, not people.
  def companion_users
    User.where(id: ByteConversation.where(mode: :buddy).select(:user_id)).order(:username).to_a
  end

  # `user_id` of "all" queues one row per person, because delivery is tracked
  # per person — see BuddyAnnouncement.
  def create_announcement
    body = params[:body].to_s.strip
    return redirect_to(system_announcements_path, alert: "Nothing to say.") if body.empty?

    targets = (
      if params[:user_id].to_s == "all"
        companion_users
      else
        User.where(id: params[:user_id]).to_a
      end
    )
    return redirect_to(system_announcements_path, alert: "No one to tell.") if targets.empty?

    hours = params[:expires_in_hours].to_i
    expires_in = hours.positive? ? hours.hours : nil
    targets.each { |user| Buddy::Announcements.queue!(user: user, body: body, expires_in: expires_in) }

    who = targets.one? ? targets.first.first_name : "#{targets.size} people"
    redirect_to(system_announcements_path, notice: "Queued for #{who}. It'll land on their next Today.")
  end

  def destroy_announcement
    BuddyAnnouncement.find(params[:id]).destroy!
    redirect_to(system_announcements_path, notice: "Removed.")
  end

  # Put a delivered one back in the queue. The reason `delivered_at` is a stamp
  # rather than a delete: a briefing that failed after the claim leaves an
  # announcement nobody heard, and this is the one click that fixes it.
  def requeue_announcement
    BuddyAnnouncement.find(params[:id]).update!(delivered_at: nil)
    redirect_to(system_announcements_path, notice: "Back in the queue.")
  end

  def connections
    @pool_stat = load_pool_stat
    @db_connections = load_db_connections
    @db_summary = @db_connections.group_by { |row| row["state"] || "unknown" }.transform_values(&:count)
    @ws_connections = load_ws_connections
    @ws_worker_pid = Process.pid
  end

  private

  # One `field:value` term, negated or not.
  def field_term(field)
    /(?:NOT\s+|-)?#{field}:#{SEARCH_VALUE}/i
  end

  # The query with this field's clause taken out, in either shape this page
  # writes: a lone `field:value`, or `(field:a OR field:b)` once several are
  # picked. Taken out WHOLE — removing the terms and leaving the parentheses and
  # the ORs behind would not parse.
  def without_clause(field)
    term = field_term(field)

    stripped = @query.gsub(/\(\s*#{term}(?:\s+OR\s+#{term})*\s*\)/i, " ")
    stripped.gsub(/(?:\A|\s)#{term}/i, " ").squish
  end

  # What is currently picked for this field. Reads through an opening paren so
  # the OR form is seen, and not through a `-`, because a negated term names
  # something to EXCLUDE and is not a selection.
  def selected_values(field)
    pattern = /(?:\A|[\s(])#{field}:(?:"([^"]*)"|'([^']*)'|([^\s)]+))/i

    @query.scan(pattern).map { |quoted, single, bare| (quoted || single || bare).to_s.downcase }
  end

  # The query with `value` added to this field's selection, or taken out of it
  # if it is already in — everything picked ORed together, and whatever else was
  # typed left where it is. Clicking the same thing twice undoes itself.
  #
  # `options` is what the page is currently offering, in the order it offers it,
  # and the result is intersected with it: a value no longer on screen cannot be
  # clicked off, so carrying it forward would strand the filter.
  def toggled_query(field, value, options)
    picked = selected_values(field)
    wanted = (
      picked.include?(value.to_s.downcase) ? picked - [value.to_s.downcase] : picked + [value.to_s.downcase]
    )
    ordered = options.select { |option| wanted.include?(option.to_s.downcase) }

    [without_clause(field), clause_for(field, ordered)].compact_blank.join(" ")
  end

  def clause_for(field, values)
    terms = values.map { |value| "#{field}:#{value.to_s.match?(/\s/) ? value.to_s.inspect : value}" }
    return nil if terms.empty?
    return terms.first if terms.one?

    "(#{terms.join(" OR ")})"
  end

  # Clicking accounts builds an OR of them, so the listing can be scoped to two
  # cards at once, and clicking one already picked drops it.
  #
  # Keyed by last four rather than by name: it is the only thing an account can
  # be matched on that cannot also match another account, and a name the search
  # would find two of would silently widen the filter. An account without one
  # gets no filter at all rather than a guess — see the missing-over-wrong rule.
  def account_filters
    options = @accounts.filter_map(&:last4)
    picked = selected_values(:account)

    @accounts.to_h { |account|
      next [account.id, nil] if account.last4.blank?

      [account.id, {
        query:  toggled_query(:account, account.last4, options),
        active: picked.include?(account.last4.downcase),
      }]
    }
  end

  # The chart's legend, which is also its category picker. It lists everything
  # the REST of the search allows rather than only what is on the chart —
  # otherwise picking one category removes every other one from the legend and
  # there is nothing left to click.
  #
  # Totals come from that same wider set, so they hold still as you pick: each
  # one says what that category is worth in this date range and payee filter,
  # which is the number you are choosing between.
  def legend_entries(real)
    totals = legend_scope(real).group(:category).sum(:amount_cents)
    ordered = totals.sort_by { |_category, cents| -cents.abs }
    # `none` is what the search calls an uncategorized row, so it is selectable
    # like any other value.
    options = ordered.map { |category, _cents| category.presence || "none" }
    picked = selected_values(:category)

    ordered.map { |category, cents|
      value = category.presence || "none"
      {
        label:  category.present? ? ::TransactionCategory.label(category) : "(none)",
        color:  ::TransactionCategory.color(category),
        cents:  cents,
        active: picked.include?(value.downcase),
        query:  toggled_query(:category, value, options),
      }
    }
  end

  # Only re-runs the search when the query actually names a category. With no
  # category term the results ARE the wider set, and asking twice for the same
  # rows is the most expensive thing on the page.
  def legend_scope(real)
    return real unless @query.match?(/(?:\A|[\s(])(?:NOT\s+|-)?category:/i)

    rest = without_clause(:category)
    scope = (rest.blank? ? ::BankTransaction.all : ::BankTransaction.query(rest))
    scope.without_transfer_mirror.real_money
  rescue ::StandardError
    # The search box already reports a query it cannot parse; the legend does
    # not need to report it a second time.
    real
  end

  # The from/to the search is already asking for, as whole days, so the pickers
  # show the range that is actually in force rather than an empty pair beside a
  # query that plainly has dates in it.
  #
  # Reported INCLUSIVELY, which is what a date picker means: `timestamp>2026-07-01`
  # begins on the 2nd, so that is the date shown. The parser answers with the
  # edge of the unit the operator lands on, and the second of slack is what
  # turns that edge back into the first day actually matched.
  def query_dates
    from = nil
    to = nil

    @query.scan(TIMESTAMP_TERM) { |operator, value|
      if operator.start_with?(">")
        at = boundary(value, operator == ">" ? :> : :>=)
        from = (operator == ">" ? at + 1.second : at) if at
      elsif operator.start_with?("<")
        at = boundary(value, operator == "<" ? :< : :<=)
        to = (operator == "<" ? at - 1.second : at) if at
      else
        # A bare `timestamp:2026-07` names a whole unit, so it sets both ends.
        span = ::BankTransaction.parse_date(value, range: true)
        next unless span.is_a?(::Range)

        from = span.first
        to = span.last
      end
    }

    [from&.to_date, to&.to_date]
  end

  # Nil rather than whatever was typed. `parse_date` hands back the raw string
  # when it cannot read one, and doing date arithmetic on that raises — a typo
  # in the search box must not take the page down.
  def boundary(value, operator)
    parsed = ::BankTransaction.parse_date(value, operator: operator)
    parsed.acts_like?(:time) ? parsed : nil
  end

  # Every row can hold a category now, so the only way this fails is a value
  # outside the vocabulary.
  def category_error(_transaction)
    "#{params[:category]} is not one of the #{::TransactionCategory::ALL.size} categories."
  end

  # A malformed query is a typo, not a 500. Surfaces the parser's own message
  # and shows nothing, rather than silently falling back to every row — which
  # would read as "your filter matched everything".
  def filtered_transactions
    return ::BankTransaction.all if @query.blank?

    ::BankTransaction.query(@query)
  rescue ::StandardError => e
    @search_error = e.message
    ::BankTransaction.none
  end

  # Spending only. Income and refunds in the same bars would net categories
  # against each other and make a bar mean two different things.
  #
  # Reads the column rather than joining action_events, which is the point of
  # the column existing: the join silently dropped every row without an alert
  # behind it, so the chart described only the part of your spending that
  # happened to arrive by email.
  def category_totals(scope)
    totals = scope.spending.group(:category).sum(:amount_cents)
    totals.filter_map { |category, cents|
      next if category.blank?

      [category, cents.abs]
    }.sort_by { |_category, cents| -cents }
  end

  # ActiveRecord's own view of THIS process's pool: how many connections are
  # checked out (busy) vs waiting threads blocked for one. `waiting` climbing
  # above zero is the direct precursor to ConnectionTimeoutError — something
  # pg_stat_activity can't show, since a connection held by Ruby during a
  # non-DB call (e.g. a Mac round-trip) reads as `idle` there while still
  # being `busy` here.
  def load_pool_stat
    ActiveRecord::Base.connection_pool.stat
  rescue StandardError => e
    Rails.logger.warn("[/system/connections] pool stat failed: #{e.message}")
    {}
  end

  def require_me
    head :not_found unless current_user&.me?
  end

  # Each returns [scope, grouped_by_[bucket, user_id], buckets, labels, calls_by_bucket].

  def daily_spend
    tz = ActiveSupport::TimeZone[SPEND_ZONE]
    start_date = tz.today - (@days - 1)
    scope = BuddyUsage.where(created_at: start_date.in_time_zone(tz).beginning_of_day..)
    grouped = scope.group(spend_day_sql, :user_id).sum(:cost_micros)
    calls = scope.group(spend_day_sql).count
    buckets = (start_date..tz.today).to_a
    [scope, grouped, buckets, buckets.map { |d| d.strftime("%b %-d") }, calls]
  end

  def hourly_spend
    tz = ActiveSupport::TimeZone[SPEND_ZONE]
    end_hour = tz.now.beginning_of_hour
    start_hour = end_hour - 23.hours
    scope = BuddyUsage.where(created_at: start_hour..)
    grouped = scope.group(spend_hour_sql, :user_id).sum(:cost_micros)
    grouped = grouped.transform_keys { |(hour, user_id)| [hour.to_i, user_id] }
    calls = scope.group(spend_hour_sql).count.transform_keys(&:to_i)
    # Chronological hour-of-day for each of the last 24 hourly slots; each hour
    # appears exactly once across a 24-hour window, so it doubles as the group key.
    buckets = (0..23).map { |i| (start_hour + i.hours).hour }
    [scope, grouped, buckets, buckets.map { |h| Time.zone.local(2000, 1, 1, h).strftime("%-l %p") }, calls]
  end

  # created_at is `timestamp without time zone` holding UTC, so re-anchor it to
  # UTC before converting to the local zone, then bucket in that zone.
  def spend_day_sql
    Arel.sql("(created_at AT TIME ZONE 'UTC' AT TIME ZONE '#{SPEND_ZONE}')::date")
  end

  def spend_hour_sql
    Arel.sql("EXTRACT(HOUR FROM (created_at AT TIME ZONE 'UTC' AT TIME ZONE '#{SPEND_ZONE}'))::int")
  end

  def load_db_connections
    conn = ActiveRecord::Base.connection
    pg_version = conn.send(:postgresql_version)
    waiting_select = (
      if pg_version >= 90_600
        "wait_event_type IS NOT NULL AS waiting, wait_event_type, wait_event"
      else
        "waiting, NULL::text AS wait_event_type, NULL::text AS wait_event"
      end
    )
    sql = <<~SQL.squish
      SELECT pid,
             datname,
             usename,
             application_name,
             client_addr,
             backend_start,
             xact_start,
             query_start,
             state_change,
             state,
             #{waiting_select},
             query
      FROM pg_stat_activity
      WHERE datname = current_database()
      ORDER BY COALESCE(query_start, backend_start) DESC
    SQL
    conn.exec_query(sql).to_a
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("[/system/connections] pg_stat_activity query failed: #{e.message}")
    []
  end

  def load_ws_connections
    server = ActionCable.server
    server.connections.map { |conn|
      env = conn.respond_to?(:env) ? (conn.env || {}) : {}
      user = conn.respond_to?(:current_user) ? conn.current_user : nil
      stats = conn.respond_to?(:statistics) ? conn.statistics : {}
      subs = conn.subscriptions.identifiers.to_a.map { |id|
        parsed = (JSON.parse(id) rescue { "channel" => id })
        {
          channel: parsed["channel"] || id,
          params:  parsed.except("channel"),
        }
      }
      http_headers = env.select { |k, _| k.is_a?(String) && k.start_with?("HTTP_") }
      {
        object_id:            conn.object_id,
        user_id:              user&.id,
        username:             user.respond_to?(:username) ? user&.username : nil,
        identifier:           conn.connection_identifier,
        started_at:           stats[:started_at] || conn.instance_variable_get(:@started_at),
        request_id:           stats[:request_id],
        remote_ip:            env["HTTP_X_FORWARDED_FOR"].to_s.split(",").first&.strip.presence || env["REMOTE_ADDR"],
        user_agent:           env["HTTP_USER_AGENT"],
        referer:              env["HTTP_REFERER"],
        origin:               env["HTTP_ORIGIN"],
        http_headers:         http_headers,
        last_transmitted_at:  conn.respond_to?(:last_transmitted_at) ? conn.last_transmitted_at : nil,
        transmissions_count:  conn.respond_to?(:transmissions_count) ? conn.transmissions_count : nil,
        pings_count:          conn.respond_to?(:pings_count) ? conn.pings_count.to_i : 0,
        last_message_summary: conn.respond_to?(:last_message_summary) ? conn.last_message_summary : nil,
        recent_ids:           conn.respond_to?(:recent_ids) ? (conn.recent_ids || []) : [],
        subscriptions:        subs,
      }
    }
  rescue StandardError => e
    Rails.logger.warn("[/system/connections] ActionCable connections enumeration failed: #{e.message}")
    []
  end
end
