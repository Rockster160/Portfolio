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
      move_user_lists_to_user
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

  def move_user_lists_to_user
    @invitation_token = params.dig(:user, :invitation_token)
    if @invitation_token.present?
      temp_user = User.where.not(invitation_token: nil).find_by_invitation_token(@invitation_token)
      temp_user.user_lists.each do |user_list|
        @user.user_lists.find_or_create_by(list_id: user_list.list_id)
      end
      temp_user.destroy
    end
  end

  def user_params
    params.require(:user).permit(:username, :password)
  end

end
