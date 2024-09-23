class JilTasksController < ApplicationController
  def index
    # @tasks = current_user.jil_tasks.ordered
    @tasks = current_user.jil_tasks.order("last_trigger_at DESC NULLS LAST")
  end

  def show
    @task = current_user.jil_tasks.find(params[:id])

    render "form", layout: "jil"
  end

  def new
    @task = current_user.jil_tasks.new

    render "form", layout: "jil"
  end

  def create
    @task = current_user.jil_tasks.create(jil_task_params)

    render json: {
      data: @task.serialize,
      url: jil_task_path(@task),
    }
  end

  def update
    @task = current_user.jil_tasks.find(params[:id])
    @task.update(jil_task_params)

    render json: {
      data: @task.serialize,
      url: jil_task_path(@task),
    }
  end

  def run
    @task = current_user.jil_tasks.find_by(id: params[:id]) unless params[:id] == "new"
    code = params[:code]
    data = params[:data]

    ::Jil::Executor.async_call(current_user, code, data || {}, task: @task)

    head :ok
  end

  private

  def jil_task_params
    params.require(:jil_task).permit(
      :name,
      :cron,
      :listener,
      :code,
    )
  end
end
