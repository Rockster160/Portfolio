class PagesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest, :set_page

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

  def edit
    authorize_owner
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

  def update
    authorize_owner
    if @page.update(page_params)
      respond_to do |format|
        format.html { redirect_to @page }
        format.json { render json: @page.to_full_packet }
      end
    else
      render :form
    end
  end

  def shared_users
    authorize_owner
    username = params[:username].to_s.strip

    if params[:remove].present?
      user = User.find_by(id: params[:remove])
      @page.shared_pages.where(user: user).destroy_all if user
    elsif username.present?
      user = User.by_username(username).first
      if user && user.id != current_user.id
        @page.shared_pages.find_or_create_by(user: user)
      end
    end

    render json: { shared_users: @page.shared_users.map { |u| { id: u.id, username: u.username } } }
  end

  def destroy
    authorize_owner
    if @page.destroy
      redirect_to pages_path
    else
      redirect_to @page, alert: "Failed to delete page: #{@page.errors.full_messages.join("\n")}"
    end
  end

  private

  def authorize_owner
    return if @page.user == current_user

    redirect_to @page, alert: "You cannot make changes to this page."
  end

  def set_page
    return unless params[:id].present?

    @page = current_user.pages.find_by(id: params[:id])
    @page ||= current_user.accessible_shared_pages.find(params[:id])
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
