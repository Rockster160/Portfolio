class Users::SessionsController < ApplicationController
  before_action :unauthorize_user, except: [ :destroy ]
  before_action :authorize_user, only: [ :destroy ]

  def new
    @user = User.new
  end

  def create
    @user = User.attempt_login(user_params[:username], user_params[:password])

    if @user.present?
      sign_in @user
      redirect_to session[:forwarding_url] || lists_path
    else
      @user = User.new(username: user_params[:username])
      @user.errors.add(:base, "Username and password combination not found.")
      render :new
    end
  end

  def destroy
    sign_out
    redirect_to login_path
  end

  private

  def user_params
    params.require(:user).permit(:username, :password)
  end

end
