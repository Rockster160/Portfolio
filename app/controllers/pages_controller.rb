class PagesController < ApplicationController
  before_action :authorize_user, :set_page

  def index
    @pages = current_user.pages.order(:created_at)
  end

  def show
  end

  def new
    @page = current_user.pages.new

    render :form
  end

  def create
    @page = current_user.pages.new(page_params)

    if @page.save
      redirect_to @page
    else
      render :form
    end
  end

  def edit
    render :form
  end

  def update
    if @page.update(page_params)
      redirect_to @page
    else
      render :form
    end
  end

  def destroy
    if @page.destroy
      redirect_to pages_path
    else
      redirect_to @page, alert: "Failed to delete page: #{@page.errors.full_messages.join("\n")}"
    end
  end

  private

  def set_page
    @page = current_user.pages.find(params[:id]) if params[:id].present?
  end

  def page_params
    params.require(:page).permit(
      :folder_id,
      :name,
      :tag_strings,
      :content,
    )
  end
end
