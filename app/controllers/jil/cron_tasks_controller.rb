class Jil::CronTasksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def show
    @task = current_user.cron_tasks.find(params[:id])
    redirect_to edit_jil_cron_task_path(@task)
  end

  def index
    @tasks = current_user.cron_tasks.order(enabled: :desc, next_trigger_at: :asc, last_trigger_at: :desc)
  end

  def new
    @task = current_user.cron_tasks.new

    render :form
  end

  def edit
    @task = current_user.cron_tasks.find(params[:id])

    render :form
  end

  def update
    @task = current_user.cron_tasks.find(params[:id])
    @task.update(task_params)
    ::BroadcastUpcomingWorker.perform_async

    redirect_to jil_cron_tasks_path
  end

  def create
    @task = current_user.cron_tasks.create(task_params)

    ::BroadcastUpcomingWorker.perform_async

    redirect_to jil_cron_tasks_path
  end

  def destroy
    @task = current_user.cron_tasks.find(params[:id])

    if @task.destroy
      ::BroadcastUpcomingWorker.perform_async
      redirect_to jil_cron_tasks_path
    else
      redirect_to jil_cron_tasks_path
    end
  end

  private

  def task_params
    params.require(:cron_task).permit(
      :command,
      :cron,
      :enabled,
      :name,
    )
  end
end
