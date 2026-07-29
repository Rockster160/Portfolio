class SystemController < ApplicationController
  before_action :require_me

  # Buddy usage timestamps are UTC; spend is bucketed by local calendar day so a
  # late-night turn lands on the day it felt like, not the next UTC one.
  SPEND_ZONE = "America/Denver".freeze
  # A window of 1 means "today, hour by hour"; the rest are rolling day windows.
  SPEND_WINDOWS = [1, 7, 30, 90].freeze
  SPEND_DEFAULT_DAYS = 30
  # Dark-theme palette, assigned to models by spend rank.
  SPEND_PALETTE = %w[
    #5DADE2 #58D68D #F5B041 #AF7AC5 #EC7063 #48C9B0 #F7DC6F #5499C7
  ].freeze

  def index; end

  def gpt_spending
    @windows = SPEND_WINDOWS
    @days = params[:days].to_i
    @days = SPEND_DEFAULT_DAYS unless SPEND_WINDOWS.include?(@days)
    @hourly = @days == 1

    scope, grouped, @buckets, @labels = @hourly ? hourly_spend : daily_spend

    @model_totals = grouped.each_with_object(Hash.new(0)) { |((_bucket, model), micros), totals|
      totals[model] += micros
    }.sort_by { |_model, micros| -micros }
    @models = @model_totals.map(&:first)

    @colors = @models.each_with_index.to_h { |model, i| [model, SPEND_PALETTE[i % SPEND_PALETTE.length]] }
    @datasets = @models.map { |model|
      {
        model: model,
        color: @colors[model],
        data:  @buckets.map { |bucket| (grouped[[bucket, model]] || 0) / Buddy::GPT::Pricing::MICROS_PER_DOLLAR.to_f },
      }
    }
    @total_micros = grouped.values.sum
    @call_count = scope.count

    divisor = @hourly ? 24 : @days
    @avg_micros = divisor.positive? ? @total_micros / divisor : 0
    @total_label = @hourly ? "Total, today" : "Total, last #{@days} days"
    @avg_label = @hourly ? "Per hour (avg)" : "Per day (avg)"
  end

  def connections
    @pool_stat = load_pool_stat
    @db_connections = load_db_connections
    @db_summary = @db_connections.group_by { |row| row["state"] || "unknown" }.transform_values(&:count)
    @ws_connections = load_ws_connections
    @ws_worker_pid = Process.pid
  end

  private

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

  # Each returns [scope, grouped_by_[bucket, model], buckets, labels].

  def daily_spend
    tz = ActiveSupport::TimeZone[SPEND_ZONE]
    start_date = tz.today - (@days - 1)
    scope = BuddyUsage.where(created_at: start_date.in_time_zone(tz).beginning_of_day..)
    grouped = scope.group(spend_day_sql, :model).sum(:cost_micros)
    buckets = (start_date..tz.today).to_a
    [scope, grouped, buckets, buckets.map { |d| d.strftime("%b %-d") }]
  end

  def hourly_spend
    tz = ActiveSupport::TimeZone[SPEND_ZONE]
    day_start = tz.now.beginning_of_day
    scope = BuddyUsage.where(created_at: day_start...(day_start + 1.day))
    grouped = scope.group(spend_hour_sql, :model).sum(:cost_micros)
    grouped = grouped.transform_keys { |(hour, model)| [hour.to_i, model] }
    buckets = (0..23).to_a
    [scope, grouped, buckets, buckets.map { |h| Time.zone.local(2000, 1, 1, h).strftime("%-l %p") }]
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
