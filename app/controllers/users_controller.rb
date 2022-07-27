class UsersController < ApplicationController
  before_action :authorize_user
  skip_before_action :verify_authenticity_token, raise: false

  def new
    @user = User.new
  end

  def create
    @list = List.find_by_id(params[:list_id])
    @user = User.find_or_create_by_filtered_params(user_params)
    @user.assign_invitation_token unless @user.persisted?

    if @user.save
      @user.invite!(@list)
      redirect_to @list
    else
      render :new
    end
  end

  def account
    @user = current_user
  end

  def update
    @user = current_user

    success = @user.update_with_password(user_params)

    if success
      redirect_to account_path
    else
      render :account
    end
  end

  private

  def user_params
    params.require(:user).permit(
      :phone,
      :email,
      :username,
      :dark_mode,
      :password,
      :password_confirmation,
      :current_password
    ).reject { |_, v| v.blank? }
  end
end
