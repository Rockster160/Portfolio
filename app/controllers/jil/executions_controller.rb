class Jil::ExecutionsController < ApplicationController
  before_action :authorize_user
  skip_before_action :verify_authenticity_token

  def index
    @executions = current_user.executions.includes(:task)

    @executions = @executions.where(task_id: params[:task_id]) if params[:task_id].present?
    @task = current_user.accessible_tasks.find(params[:task_id]) if params[:task_id].present?

    @executions = filter_executions(@executions) if params[:status].present?
    @executions = @executions.order(started_at: :desc).page(params[:page]).per(50)
  end

  WINDOW_OPTIONS = {
    "1h"  => { duration: 1.hour,    bucket_seconds: 60,   label: "Last hour" },
    "6h"  => { duration: 6.hours,   bucket_seconds: 300,  label: "Last 6 hours" },
    "24h" => { duration: 24.hours,  bucket_seconds: 900,  label: "Last 24 hours" },
    "7d"  => { duration: 7.days,    bucket_seconds: 3600, label: "Last 7 days" },
  }.freeze

  def dashboard
    @window_key = WINDOW_OPTIONS.key?(params[:window]) ? params[:window] : "1h"
    window = WINDOW_OPTIONS[@window_key]
    @window_label = window[:label]
    @bucket_seconds = window[:bucket_seconds]
    @since = Time.current - window[:duration]
    @rapid_threshold = (params[:rapid_threshold].presence || 10).to_i

    @task = current_user.accessible_tasks.find(params[:task_id]) if params[:task_id].present?

    user_id = current_user.id
    scope = Execution.where(user_id: user_id).where(started_at: @since..)
    scope = scope.where(task_id: @task.id) if @task

    @total_count = scope.count

    failed_id = Execution.statuses[:failed]

    if @task
      @status_breakdown = scope.group(:status).count.transform_keys { |k| Execution.statuses[k] || k }
      @auth_breakdown = scope.group(:auth_type).count.transform_keys { |k| Execution.auth_types[k] || k }
      @avg_duration = scope.where.not(finished_at: nil).pick(
        Arel.sql("AVG(EXTRACT(EPOCH FROM (finished_at - started_at)))"),
      )&.to_f
      @top_offenders = []
      @task_lookup = { @task.id => @task }
    else
      @top_offenders = scope.group(:task_id).select(
        "task_id",
        "COUNT(*) AS execution_count",
        "SUM(CASE WHEN status = #{failed_id} THEN 1 ELSE 0 END) AS failed_count",
        "AVG(CASE WHEN finished_at IS NOT NULL THEN EXTRACT(EPOCH FROM (finished_at - started_at)) END) AS avg_duration",
        "MAX(started_at) AS last_started_at",
      ).order(execution_count: :desc).limit(25).to_a

      task_ids = @top_offenders.map(&:task_id).compact
      @task_lookup = Task.where(id: task_ids).index_by(&:id)
    end

    task_filter_sql = @task ? "AND task_id = ?" : ""
    task_filter_args = @task ? [@task.id] : []

    @histogram = ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT to_timestamp(floor(extract(epoch from started_at) / ?) * ?) AS bucket,
                 status,
                 COUNT(*) AS count
          FROM executions
          WHERE user_id = ? AND started_at >= ? #{task_filter_sql}
          GROUP BY bucket, status
          ORDER BY bucket
        SQL
        @bucket_seconds,
        @bucket_seconds,
        user_id,
        @since,
        *task_filter_args,
      ]),
    ).to_a

    @rapid_fire = ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT task_id,
                 COUNT(*) AS rapid_count,
                 MIN(gap) AS min_gap,
                 percentile_cont(0.5) WITHIN GROUP (ORDER BY gap) AS median_gap,
                 MAX(started_at) AS last_started_at
          FROM (
            SELECT task_id,
                   started_at,
                   EXTRACT(EPOCH FROM (started_at - LAG(started_at) OVER (PARTITION BY task_id ORDER BY started_at))) AS gap
            FROM executions
            WHERE user_id = ? AND started_at >= ? AND task_id IS NOT NULL #{task_filter_sql}
          ) sub
          WHERE gap IS NOT NULL AND gap < ?
          GROUP BY task_id
          ORDER BY rapid_count DESC, min_gap ASC
          LIMIT 25
        SQL
        user_id,
        @since,
        *task_filter_args,
        @rapid_threshold,
      ]),
    ).to_a

    rapid_task_ids = @rapid_fire.pluck("task_id").compact - @task_lookup.keys
    @task_lookup.merge!(Task.where(id: rapid_task_ids).index_by(&:id)) if rapid_task_ids.any?
  end

  def show
    @execution = find_execution(params[:id])
    # @task = @execution.task
    field = params[:field]

    case field
    when "code"
      content = @execution.code
      render json: { content: content, compacted: content.nil?, type: "code" }
    when "ctx"
      ctx = @execution.ctx || {}
      render json: {
        compacted:     ctx.nil?,
        type:          "ctx",
        line:          ctx["line"],
        state:         ctx["state"],
        time_start:    ctx["time_start"] ? format_timestamp(ctx["time_start"]) : nil,
        time_complete: ctx["time_complete"] ? format_timestamp(ctx["time_complete"]) : nil,
        return_val:    ctx["return_val"],
        output:        ctx["output"],
        error:         ctx["error"],
        error_line:    ctx["error_line"],
        other:         ctx.except("line", "state", "time_start", "time_complete", "return_val", "output", "error", "error_line"),
      }
    when "input_data"
      data = @execution.input_data
      if data.is_a?(String)
        # String trigger data (e.g., "gid://Jarvis/ActionEvent/39275")
        render json: { content: data, compacted: false, empty: data.blank?, type: "input_data", format: "string" }
      else
        data ||= {}
        # Check if it's the default empty state
        is_empty = data == { "match_list" => [], "named_captures" => {} } ||
          data == { match_list: [], named_captures: {} } ||
          data.blank?
        render json: { content: is_empty ? nil : JSON.pretty_generate(data), compacted: data.nil?, empty: is_empty, type: "input_data", format: "json" }
      end
    else
      head :bad_request
    end
  end

  def replay
    @execution = find_execution(params[:id])

    if @execution.code.blank?
      flash[:alert] = "Cannot replay: execution data has been compacted"
      return redirect_back(fallback_location: jil_executions_path)
    end

    task = @execution.task
    run_as_user = task&.user_id == current_user.id ? current_user : (task&.user || current_user)
    code = @execution.code
    input_data = @execution.input_data || {}

    ::Jil::Executor.async_call(run_as_user, code, input_data, task: task, auth: :run)

    flash[:notice] = "Execution replayed successfully"
    redirect_back(fallback_location: task ? jil_task_executions_path(task) : jil_executions_path)
  end

  private

  def find_execution(id)
    current_user.executions.find(id)
  end

  def filter_executions(executions)
    statuses = params[:status].split(",").map(&:strip)
    executions.where(status: statuses)
  end

  def format_timestamp(ts)
    return nil unless ts

    time = if ts.is_a?(Numeric)
      Time.zone.at(ts / 1000.0)
    else
      Time.zone.parse(ts.to_s)
    end
    time.in_time_zone(current_user.timezone).strftime("%a %b %d, %Y at %I:%M:%S %p %Z")
  rescue StandardError
    ts.to_s
  end
end
