class SystemController < ApplicationController
  before_action :require_me

  # Buddy usage timestamps are UTC; spend is bucketed by local calendar day so a
  # late-night turn lands on the day it felt like, not the next UTC one.
  SPEND_ZONE = "America/Denver".freeze
  # A window of 1 means "last 24 hours, hour by hour"; the rest are rolling day windows.
  SPEND_WINDOWS = [1, 7, 30, 90].freeze
  SPEND_DEFAULT_DAYS = 30
  TRANSACTION_PAGE = 100
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
    @stray_categories = ::TransactionCategory.unknown_in_use
    @unlinked_count = ::BankTransaction.unlinked.count
    @backfill = ::SimpleFin::Backfill.progress

    @query = params[:q].to_s.strip
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
    skipped = 0
    # No ActionEventNotifier here on purpose: it fires a :event Jil trigger per
    # event, and a bulk recategorise of a whole search would stampede every
    # watch and automation listening for one. ActionEventNotifier exists so
    # bulk paths can opt out — this is one.
    scope.includes(:action_event).find_each { |transaction|
      transaction.apply_category(category) ? updated += 1 : skipped += 1
    }

    notice = "Categorised #{updated} as #{::TransactionCategory.label(category)}."
    notice += " #{skipped} skipped (no linked event to hold a category)." if skipped.positive?
    redirect_to(system_banking_path(q: params[:q].presence), notice: notice)
  end

  def connections
    @pool_stat = load_pool_stat
    @db_connections = load_db_connections
    @db_summary = @db_connections.group_by { |row| row["state"] || "unknown" }.transform_values(&:count)
    @ws_connections = load_ws_connections
    @ws_worker_pid = Process.pid
  end

  private

  # Category is stored on the linked event, so an unlinked row has nowhere to
  # put one. Say which of the two it is rather than a generic failure.
  def category_error(transaction)
    return "No linked event to hold a category." if transaction.action_event.blank?

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
  def category_totals(scope)
    totals = scope.spending.joins(:action_event)
    totals = totals.group(::Arel.sql("action_events.data->>'category'"))
    totals = totals.sum(:amount_cents)
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
        object_id:           conn.object_id,
        user_id:             user&.id,
        username:            user.respond_to?(:username) ? user&.username : nil,
        identifier:          conn.connection_identifier,
        started_at:          stats[:started_at] || conn.instance_variable_get(:@started_at),
        request_id:          stats[:request_id],
        remote_ip:           env["HTTP_X_FORWARDED_FOR"].to_s.split(",").first&.strip.presence || env["REMOTE_ADDR"],
        user_agent:          env["HTTP_USER_AGENT"],
        referer:             env["HTTP_REFERER"],
        origin:              env["HTTP_ORIGIN"],
        http_headers:        http_headers,
        last_transmitted_at: conn.respond_to?(:last_transmitted_at) ? conn.last_transmitted_at : nil,
        transmissions_count: conn.respond_to?(:transmissions_count) ? conn.transmissions_count : nil,
        pings_count:         conn.respond_to?(:pings_count) ? conn.pings_count.to_i : 0,
        last_message_summary: conn.respond_to?(:last_message_summary) ? conn.last_message_summary : nil,
        recent_ids:          conn.respond_to?(:recent_ids) ? (conn.recent_ids || []) : [],
        subscriptions:       subs,
      }
    }
  rescue StandardError => e
    Rails.logger.warn("[/system/connections] ActionCable connections enumeration failed: #{e.message}")
    []
  end
end
