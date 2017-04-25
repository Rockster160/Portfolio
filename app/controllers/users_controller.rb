class UsersController < ApplicationController

  def new
    @user = User.new
  end

  def create
    @list = List.find_by_id(params[:list_id])
    @user = User.find_by(user_params) || User.new(user_params)

    @user.assign_invitation_token unless @user.persisted?

    if @user.save
      add_user_to_list
      # TODO: Invite user via Text with invitation token
      redirect_to @list
    else
      render :new
    end
  end

  private

  def add_user_to_list
    return unless @list.present?
    @list.user_lists.create(user_id: @user.id)
  end

  def user_params
    params.require(:user).permit(:phone)
  end

end
