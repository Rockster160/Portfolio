class Jil::JarvisTasksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @tasks = current_user.jarvis_tasks
  end

  def new
    @task = current_user.jarvis_tasks.new

    render :form
  end

  def edit
    @task = current_user.jarvis_tasks.find(params[:id])

    render :form
  end

  def update
    @task = current_user.jarvis_tasks.find(params[:id])
    @task.update(task_params)

    respond_to do |format|
      format.json { render json: { status: :found, url: edit_jil_jarvis_task_path(@task) } }
    end
  end

  def create
    @task = current_user.jarvis_tasks.create(task_params)

    respond_to do |format|
      format.json { render json: { status: :found, url: edit_jil_jarvis_task_path(@task) } }
    end
  end

  def destroy
    @task = current_user.jarvis_tasks.find(params[:id])

    if @task.destroy
      redirect_to :jil
    else
      redirect_to [:jil, @task, :edit]
    end
  end

  def run
    @task = current_user.jarvis_tasks.find(params[:id])
    ::Jarvis::Execute.call(@task, test_mode: true)

    respond_to do |format|
      format.json
    end
  end

  private

  def task_params
    params.require(:jarvis_task).permit(
      :name,
      :trigger,
      :cron,
      :tasks,
    ).tap { |whitelist|
      if whitelist[:cron].present?
        whitelist[:next_trigger_at] = Time.at(Fugit::Cron.parse(whitelist[:cron]).next_time.to_i)
      else
        whitelist[:next_trigger_at] = nil
      end
      begin
        whitelist[:tasks] = JSON.parse(whitelist[:tasks]) if whitelist[:tasks].is_a?(String)
      rescue JSON::ParserError
      end
    }
  end
end
