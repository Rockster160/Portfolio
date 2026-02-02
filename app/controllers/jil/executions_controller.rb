class Jil::ExecutionsController < ApplicationController
  before_action :authorize_user
  skip_before_action :verify_authenticity_token

  def index
    @executions = current_user.executions.includes(:task)

    @executions = @executions.where(task_id: params[:task_id]) if params[:task_id].present?

    @executions = filter_executions(@executions) if params[:status].present?
    @executions = @executions.order(started_at: :desc).page(params[:page]).per(50)
  end

  def show
    @execution = find_execution(params[:id])
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
