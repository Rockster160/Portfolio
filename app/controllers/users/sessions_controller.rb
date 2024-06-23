class Users::SessionsController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :show_guest_banner
  before_action :unauthorize_user, :set_invitation_token, except: [ :destroy ], unless: :guest_account?
  before_action :authorize_user_or_guest, only: [ :destroy ]

  def new
    @user = User.new
  end

  def create
    @user = User.attempt_login(user_params[:username], user_params[:password])

    if @user.present?
      merge_user_accounts
      sign_in @user
      move_user_lists_to_user
      redirect_to previous_url
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

  def set_invitation_token
    @invitation_token ||= params.dig(:user, :invitation_token) || params[:invitation_token]
    @invitation_hash = @invitation_token.present? ? {invitation_token: @invitation_token} : nil
  end

  def merge_user_accounts
    return unless current_user&.guest?

    @user.merge_account(current_user)
  end

  def move_user_lists_to_user
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
