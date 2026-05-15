class AgendaSharesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_agenda
  before_action :set_share, only: [:update, :destroy]

  # POST /agendas/:agenda_id/shares — body: { agenda_share: { user_id, permission } }
  # Accepts user_id (preferred — from the friend picker) or username (fallback).
  def create
    target_user = resolve_target_user
    return render json: { errors: ["Pick a friend to share with"] }, status: :unprocessable_entity if target_user.blank?
    return render json: { errors: ["Can't share with yourself"] }, status: :unprocessable_entity if target_user.id == current_user.id

    @share = @agenda.agenda_shares.find_or_initialize_by(user: target_user)
    @share.permission = permission_param

    if @share.save
      @agenda.broadcast!
      render json: serialize_share(@share)
    else
      render json: { errors: @share.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @share.update(permission: permission_param)
      @agenda.broadcast!
      render json: serialize_share(@share)
    else
      render json: { errors: @share.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @share.destroy
    @agenda.broadcast!
    head :no_content
  end

  private

  # Only the owner manages shares — not editors-of-shared.
  def set_agenda
    @agenda = current_user.agendas.find_by(id: params[:agenda_id]) ||
              current_user.agendas.by_param(params[:agenda_id]).first
    raise ActionController::RoutingError, "Not Found" if @agenda.blank?
  end

  def set_share
    @share = @agenda.agenda_shares.find(params[:id])
  end

  # Friend picker sends user_id directly. Fallback to username (typed) for
  # the legacy path, resolved through the user's contacts so nicknames like
  # "Mom" or "Chelsea's place" also work (delegates to Contact.name_find).
  def resolve_target_user
    user_id = params.dig(:agenda_share, :user_id).presence
    return current_user.friends.find_by(id: user_id) if user_id

    name = params.dig(:agenda_share, :username).to_s.strip
    return nil if name.blank?

    contact = current_user.contacts.name_find(name)
    contact&.friend || User.by_username(name).first
  end

  def permission_param
    raw = params.dig(:agenda_share, :permission).to_s
    AgendaShare.permissions.key?(raw) ? raw : :editor
  end

  def serialize_share(share)
    user = share.user
    {
      id:         share.id,
      user_id:    user.id,
      username:   user.username,
      nickname:   current_user.contacts.find_by(friend_id: user.id)&.nickname,
      permission: share.permission,
    }
  end
end
