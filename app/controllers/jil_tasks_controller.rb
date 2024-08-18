class JilTasksController < ApplicationController
  def index
    @tasks = current_user.jil_tasks.ordered
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
