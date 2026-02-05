class Jil::TasksController < ApplicationController
  before_action :authorize_user
  skip_before_action :verify_authenticity_token # User is authorized and we don't want to prevent JS

  def index
    if params[:archived].present?
      @archived = true
      @root_tasks = current_user.tasks.archived.order(archived_at: :desc)
      @folders = TaskFolder.none
      @shared_tasks = current_user.accessible_tasks.none
    else
      @folders = current_user.task_folders.includes(:children, tasks: []).roots.ordered
      @root_tasks = current_user.tasks.active.where(task_folder_id: nil).order(sort_order: :desc)
      @shared_tasks = current_user.accessible_tasks.active.where.not(user_id: current_user.id)
    end
  end

  def reorder
    if params[:item_id].present? && params[:item_type].present?
      folder_id = params[:folder_id].presence
      if params[:item_type] == "folder"
        folder = current_user.task_folders.find(params[:item_id])
        if folder_id.present? && (folder.id.to_s == folder_id.to_s || folder.ancestor_of?(current_user.task_folders.find(folder_id)))
          render json: { error: "Cannot nest folder inside itself" }, status: :unprocessable_entity
          return
        end
        folder.update_column(:parent_id, folder_id)
      else
        task = current_user.tasks.find(params[:item_id])
        task.update_column(:task_folder_id, folder_id)
      end
    end

    if params[:child_ids].present?
      count = params[:child_ids].size
      params[:child_ids].each_with_index do |child_key, idx|
        type, id = child_key.split(":")
        sort_value = count - idx
        if type == "folder"
          current_user.task_folders.where(id: id).update_all(sort_order: sort_value)
        else
          current_user.tasks.where(id: id).update_all(sort_order: sort_value)
        end
      end
    end

    Task.recompute_tree_order(current_user)
    head :ok
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
      task_folder_id:  original_task.task_folder_id,
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

  def archive
    @task = current_user.tasks.find(params[:id])
    @task.archive!
    redirect_to jil_tasks_path
  end

  def unarchive
    @task = current_user.tasks.find(params[:id])
    @task.unarchive!
    redirect_to jil_task_path(@task)
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
