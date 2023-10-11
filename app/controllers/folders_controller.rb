class FoldersController < ApplicationController
  before_action :authorize_user, :set_folder

  def index
    @folders = current_user.folders.ordered.where(folder_id: nil)
    @pages = current_user.pages.ordered.where(folder_id: nil)
  end

  def new
    @folder = current_user.folders.new

    render :form
  end

  def create
    @folder = current_user.folders.new(folder_params)

    if @folder.save
      redirect_to @folder
    else
      render :form
    end
  end

  def edit
    render :form
  end

  def update
    if @folder.update(folder_params)
      redirect_to @folder
    else
      render :form
    end
  end

  def destroy
    if @folder.destroy
      redirect_to folders_path
    else
      redirect_to @folder, alert: "Failed to delete folder: #{@folder.errors.full_messages.join("\n")}"
    end
  end

  private

  def set_folder
    @folder = current_user.folders.find(params[:id]) if params[:id].present?
  end

  def folder_params
    params.require(:folder).permit(
      :folder_id,
      :name,
      :tag_strings,
    )
  end
end
