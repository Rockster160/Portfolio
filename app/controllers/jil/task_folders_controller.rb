class Jil::TaskFoldersController < ApplicationController
  before_action :authorize_user
  skip_before_action :verify_authenticity_token

  def create
    folder = current_user.task_folders.create!(folder_params)
    render json: { id: folder.id, name: folder.name }
  end

  def update
    folder = current_user.task_folders.find(params[:id])
    folder.update!(folder_params)
    render json: { id: folder.id, name: folder.name }
  end

  def destroy
    folder = current_user.task_folders.find(params[:id])
    folder.tasks.update_all(task_folder_id: nil)
    folder.destroy!
    Task.recompute_tree_order(current_user)
    head :ok
  end

  def toggle_collapsed
    folder = current_user.task_folders.find(params[:id])
    folder.update!(collapsed: !folder.collapsed)
    render json: { collapsed: folder.collapsed }
  end

  private

  def folder_params
    params.permit(:name, :parent_id)
  end
end
