class SystemController < ApplicationController
  before_action :require_me

  def index; end

  def connections
    @db_connections = load_db_connections
    @db_summary = @db_connections.group_by { |row| row["state"] || "unknown" }.transform_values(&:count)
    @ws_connections = load_ws_connections
    @ws_worker_pid = Process.pid
  end

  private

  def require_me
    head :not_found unless current_user&.me?
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
