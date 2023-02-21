class Jil::JarvisTasksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action {  }

  def index
    if running_function?
      @tasks = current_user.jarvis_tasks.function
    else
      @tasks = current_user.jarvis_tasks.not_function
    end
  end

  def new
    @task = current_user.jarvis_tasks.new
    @task.trigger = :function if running_function?

    render :form
  end

  def edit
    @task = current_user.jarvis_tasks.find(params[:id])

    render :form
  end

  def update
    @task = current_user.jarvis_tasks.find(params[:id])
    @task.update(task_params)
    ::BroadcastUpcomingWorker.perform_async

    respond_to do |format|
      format.html { redirect_to edit_jil_jarvis_task_path(@task) if running_function? }
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

  def destroy
    @task = current_user.jarvis_tasks.find(params[:id])

    if @task.destroy
      ::BroadcastUpcomingWorker.perform_async
      redirect_to :jil
    else
      redirect_to [:jil, @task, :edit]
    end
  end

  def run
    @task = current_user.jarvis_tasks.find(params[:id])
    ::Jarvis::Execute.call(@task, { test_mode: true })
    ::BroadcastUpcomingWorker.perform_async

    respond_to do |format|
      format.json
    end
  end

  private

  def running_function?
    @running_function ||= request.path.match?(/\/jil\/functions/) || @task&.function?
  end
  helper_method :running_function?

  def task_params
    params.require(:jarvis_task).permit(
      :name,
      :trigger,
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
