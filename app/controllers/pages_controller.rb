class PagesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest, :set_page
  skip_before_action :pretty_logit

  def show
    respond_to do |format|
      format.html
      format.json { render json: @page.to_full_packet }
    end
  end

  def new
    @page = current_user.pages.new

    render :form
  end

  def create
    @page = current_user.pages.new
    @page.assign_attributes(page_params) # Separate from new to allow setting user

    if @page.save
      respond_to do |format|
        format.html { redirect_to @page }
        format.json { render json: @page.to_full_packet }
      end
    else
      render :form
    end
  end

  def edit
    render :form
  end

  def update
    if @page.update(page_params)
      respond_to do |format|
        format.html { redirect_to @page }
        format.json { render json: @page.to_full_packet }
      end
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
      :folder_name,
      :name,
      :tag_strings,
      :content,
      :timestamp,
    )
  end
end
