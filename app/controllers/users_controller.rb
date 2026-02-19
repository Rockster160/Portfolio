class UsersController < ApplicationController
  before_action :authorize_user_or_guest
  skip_before_action :verify_authenticity_token

  def new
    @user = User.new
    @list = current_user.lists.find_by(id: params[:list_id]) if params[:list_id].present?
    load_friends
  end

  def create
    @list = List.find_by(id: params[:list_id])
    @user = User.find_or_create_by_filtered_params(user_params) # Only does an initialize
    if !@user.persisted? && @list && (@user.phone.blank? && @user.email.blank?)
      # Inviting a user by list, but only giving a username, and that user doesn't exist
      @user.errors.add(:base, "No user found with that username")
      load_friends
      return render :new
    end
    @user.assign_invitation_token unless @user.persisted?

    if @user.save
      @user.invite!(@list)
      redirect_to @list
    else
      load_friends
      render :new
    end
  end

  def account
    @user = current_user
  end

  def update
    @user = current_user

    if @user.update_with_password(user_params)
      redirect_to previous_url(account_path)
    else
      render :account
    end
  end

  private

  def load_friends
    return unless @list

    existing_user_ids = @list.user_lists.pluck(:user_id)
    @friends = current_user.contacts.where.not(friend_id: nil).where.not(friend_id: existing_user_ids).order(:name)
  end

  def user_params
    params.require(:user).permit(
      :phone,
      :email,
      :username,
      :dark_mode,
      :password,
      :password_confirmation,
      :current_password,
    ).compact_blank
  end
end
