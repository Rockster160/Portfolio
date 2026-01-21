class Jil::TasksController < ApplicationController
  before_action :authorize_user
  skip_before_action :verify_authenticity_token # User is authorized and we don't want to prevent JS

  def index
    @tasks = current_user.accessible_tasks.order("last_trigger_at DESC NULLS LAST")
  end

  def show
    @task = current_user.accessible_tasks.find(params[:id])
    @readonly = @task.user_id != current_user.id

    render "form", layout: "jil"
  end

  def trigger
    @task = current_user.tasks.find(params[:id])
  end

  def new
    @task = current_user.tasks.new

    render "form", layout: "jil"
  end

  def create
    @task = current_user.tasks.create(task_params)

    render json: {
      data: @task.serialize,
      url:  jil_task_path(@task),
    }
  end

  def update
    @task = current_user.tasks.find(params[:id])
    @task.update(task_params)

    render json: {
      data: @task.serialize,
      url:  jil_task_path(@task),
    }
  end

  def duplicate
    original_task = current_user.tasks.find(params[:id])
    @task = original_task.dup
    @task.update!(
      name:            "#{@task.name} (Copy)",
      last_status:     nil,
      last_trigger_at: nil,
      sort_order:      nil,
      uuid:            nil,
    )

    redirect_to jil_task_path(@task)
  end

  def run
    @task = current_user.accessible_tasks.find_by(id: params[:id]) unless params[:id] == "new"
    is_owner = @task.nil? || @task.user_id == current_user.id
    code = is_owner ? (params[:code].presence || @task&.code) : @task.code
    run_as_user = is_owner ? current_user : @task.user
    data = params[:data].presence&.permit!&.to_unsafe_h

    ::Jil::Executor.async_call(run_as_user, code, data || {}, task: @task, auth: :run)

    head :ok
  end

  def shared_users
    @task = current_user.tasks.find(params[:id])
    username = params[:username].to_s.strip

    if params[:remove].present?
      user = User.find_by(id: params[:remove])
      @task.shared_tasks.where(user: user).destroy_all if user
    elsif username.present?
      user = User.by_username(username).first
      if user && user.id != current_user.id
        @task.shared_tasks.find_or_create_by(user: user)
      end
    end

    render json: { shared_users: @task.shared_users.map { |u| { id: u.id, username: u.username } } }
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
