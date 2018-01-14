class Users::RegistrationsController < ApplicationController
  before_action :unauthorize_user, :set_invitation_token

  def new
    @user = User.new
  end

  def create
    @invitation_token = params.dig(:user, :invitation_token)
    if @invitation_token.present?
      @user = User.where.not(invitation_token: nil).find_by_invitation_token(@invitation_token)
      @user ||= User.new(user_params)
      @user.assign_attributes(user_params)
      @user.invitation_token = nil
    else
      @user = User.new(user_params)
    end

    if @user.save
      sign_in @user
      redirect_to lists_path
    else
      @user.invitation_token = @invitation_token
      render :new
    end
  end

  private

  def set_invitation_token
    @invitation_token = params.dig(:user, :invitation_token) || params[:invitation_token]
    @invitation_hash = @invitation_token.present? ? {invitation_token: @invitation_token} : nil
  end

  def user_params
    params.require(:user).permit(:username, :password, :password_confirmation)
  end

end
