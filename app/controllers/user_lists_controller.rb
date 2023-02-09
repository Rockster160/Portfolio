class UserListsController < ApplicationController
  before_action :authorize_user, :color_scheme
  before_action :set_list, :set_current_list_user
  skip_before_action :verify_authenticity_token, raise: false

  def create
    @user = User.find(params[:id]) # Using id here for easier lookup
    return redirect_to lists_path, alert: "You do not have permission to add users to this list." unless @current_list_user.is_owner?
    @user_list = @user.user_lists.find_or_create_by(list_id: @list.id)

    redirect_to @list
  end

  def destroy
    @user = User.find(params[:id]) # Using id here for easier lookup
    @user_list = @user.user_lists.find_by(list_id: @list.id)

    return redirect_to list_user_lists_path(@list), alert: "List must have an owner." if @user_list.is_owner?

    @user_list.destroy if @current_list_user.is_owner? || @user_list == @current_list_user
    if @current_list_user == @user_list && @user_list.destroyed?
      redirect_to lists_path
    else
      redirect_to @list
    end
  end

  private

  def set_current_list_user
    @current_list_user = current_user.user_lists.find_by(list_id: @list.id)
  end

  def set_list
    @list = current_user.lists.find_by(id: params[:list_id]) || current_user.lists.select { |list| list.name.parameterize == params[:id] }.first
  end

  def color_scheme
    session[:color_scheme] = params[:style] if params[:style].present?
  end

end
