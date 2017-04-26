class UsersController < ApplicationController
  before_action :authorize_user

  def new
    @user = User.new
  end

  def create
    @list = List.find_by_id(params[:list_id])
    @user = User.find_by(user_params) || User.new(user_params)

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

    if user_params[:password].blank?
      success = @user.update_with_password(user_params_without_password)
    else
      success = @user.update_with_password(user_params)
    end

    if success
      redirect_to account_path
    else
      render :account
    end
  end

  private

  def user_params
    params.require(:user).permit(:phone, :username, :password, :password_confirmation, :current_password)
  end

  def user_params_without_password
    user_params.except(:password, :password_confirmation)
  end

end
