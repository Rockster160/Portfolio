class Jil::TasksController < ApplicationController
  before_action :authorize_user
  skip_before_action :verify_authenticity_token # User is authorized and we don't want to prevent JS

  def index
    @tasks = current_user.tasks.order("last_trigger_at DESC NULLS LAST")
  end

  def show
    @task = current_user.tasks.find(params[:id])

    render "form", layout: "jil"
  end

  def new
    @task = current_user.tasks.new

    render "form", layout: "jil"
  end

  def create
    @task = current_user.tasks.create(task_params)

    render json: {
      data: @task.legacy_serialize,
      url: jil_task_path(@task),
    }
  end

  def update
    @task = current_user.tasks.find(params[:id])
    @task.update(task_params)

    render json: {
      data: @task.legacy_serialize,
      url: jil_task_path(@task),
    }
  end

  def run
    @task = current_user.tasks.find_by(id: params[:id]) unless params[:id] == "new"
    code = params[:code]
    data = params[:data]

    ::Jil::Executor.async_call(current_user, code, data || {}, task: @task, auth: :run)

    head :ok
  end

  private

  def task_params
    params.require(:task).permit(
      :name,
      :cron,
      :listener,
      :code,
      :enabled,
    )
  end
end
