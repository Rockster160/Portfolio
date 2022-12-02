class Jil::JarvisTasksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @tasks = current_user.jarvis_task
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
    puts "\e[33m[LOGIT] | #{params.to_unsafe_h}\e[0m"
    puts "\e[36m[LOGIT] | #{params[:tasks_data]}\e[0m"

    # redirect_to [:edit, :jil, @task]
    puts "\e[31m[LOGIT] | #{@task.errors.full_messages}\e[0m"

    @task.update(task_params)

    respond_to do |format|
      format.json { render json: { status: :found, url: edit_jil_jarvis_task_path(@task) } }
    end
  end

  def create
    @task = current_user.jarvis_tasks.create(task_params)
    puts "\e[33m[LOGIT] | #{params.to_unsafe_h}\e[0m"
    puts "\e[36m[LOGIT] | #{params[:tasks_data]}\e[0m"

    # redirect_to [:edit, :jil, @task]
    puts "\e[31m[LOGIT] | #{@task.errors.full_messages}\e[0m"
    respond_to do |format|
      format.json { render json: { status: :found, url: edit_jil_jarvis_task_path(@task) } }
    end
  end

  def task_params
    params.require(:task).permit(
      :name,
      :tasks,
    ).tap { |whitelist|
      begin
        whitelist[:tasks] = JSON.parse(whitelist[:tasks]) if whitelist[:tasks].is_a?(String)
      rescue JSON::ParserError
      end
    }
  end
end
