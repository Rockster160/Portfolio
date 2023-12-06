class Jil::JarvisTasksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def index
    if params[:trigger].present?
      @tasks = current_user.jarvis_tasks.order(last_trigger_at: :desc).where(trigger: params[:trigger])
    else
      @tasks = current_user.jarvis_tasks.order(last_trigger_at: :desc)
    end
  end

  def new
    @task = current_user.jarvis_tasks.callable.new
    @task.trigger = :function if params[:trigger] == "function"

    render :form
  end

  def edit
    @task = current_user.jarvis_tasks.anyfind(params[:id])

    render :form
  end

  def update
    @task = current_user.jarvis_tasks.anyfind(params[:id])
    @task.update(task_params)
    ::BroadcastUpcomingWorker.perform_async

    respond_to do |format|
      format.html { redirect_to edit_jil_jarvis_task_path(@task) }
      format.json { render json: { status: :found, url: edit_jil_jarvis_task_path(@task) } }
    end
  end

  def create
    @task = current_user.jarvis_tasks.create(task_params)
    ::BroadcastUpcomingWorker.perform_async

    respond_to do |format|
      format.html { redirect_to edit_jil_jarvis_task_path(@task) }
      format.json { render json: { status: :found, url: edit_jil_jarvis_task_path(@task) } }
    end
  end

  def duplicate
    old_task = current_user.jarvis_tasks.anyfind(params[:id])
    @task = old_task.duplicate
    ::BroadcastUpcomingWorker.perform_async

    respond_to do |format|
      format.html { redirect_to edit_jil_jarvis_task_path(@task) }
      format.json { render json: { status: :found, url: edit_jil_jarvis_task_path(@task) } }
    end
  end

  def destroy
    @task = current_user.jarvis_tasks.anyfind(params[:id])

    if @task.destroy
      ::BroadcastUpcomingWorker.perform_async
      redirect_to :jil
    else
      redirect_to [:jil, @task, :edit]
    end
  end

  def run
    @task = current_user.jarvis_tasks.anyfind(params[:id])
    data = ::Jarvis::Execute.call(@task, { test_mode: params.fetch(:test_mode, false) })
    ::BroadcastUpcomingWorker.perform_async

    respond_to do |format|
      format.json { render json: { response: data } }
    end
  end

  private

  def task_params
    params.require(:jarvis_task).permit(
      :name,
      :trigger,
      :enabled,
      :input,
      :output_type,
      :cron,
      :tasks,
    ).tap { |whitelist|
      begin
        whitelist[:tasks] = JSON.parse(whitelist[:tasks]) if whitelist[:tasks].is_a?(String)
      rescue JSON::ParserError
      end
    }
  end
end
