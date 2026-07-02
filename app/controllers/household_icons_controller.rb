class HouseholdIconsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :ensure_household!
  before_action :set_icon, only: [:update, :destroy]

  # GET /chores/icons.json
  # Inlined into the chore page bootstrap AND fetched directly by the
  # picker's IconPool. Scoped to whatever household the current user is
  # a member of; returns [] when the user has no household yet.
  def index
    icons = @household ? @household.icons.ordered : HouseholdIcon.none
    render json: icons.map(&:as_pool_row)
  end

  # GET /chores/icons/signature
  # Tiny fingerprint of the household's icon set — the client polls this
  # on WS reconnect and only re-fetches the full pool when the value has
  # changed since its last known signature. Count is included so that
  # deletes register even when the newest-updated_at didn't move.
  def signature
    scope = @household ? @household.icons : HouseholdIcon.none
    render json: {
      updated_at: scope.maximum(:updated_at)&.utc&.iso8601(3),
      count:      scope.count,
    }
  end

  # GET /chores/icons
  # HTML page to browse / rename / delete custom icons for the household.
  # Bulk uploads (script-driven) and the in-modal cropper all funnel into
  # the same list; this is the only place to manage them.
  def manage
    @icons = @household.icons.ordered.includes(:uploaded_by_user).to_a
    @can_manage_any = current_user.can_manage_chores? || @household.manager?(current_user)
  end

  # POST /chores/icons
  # Body: { name:, keywords:, image_data: }. The client renders the
  # final cropped 128px WebP, encodes to data URL, and POSTs. We just
  # validate + persist + broadcast.
  def create
    icon = @household.icons.build(icon_params.merge(uploaded_by_user: current_user))
    if icon.save
      broadcast_changed(reason: :created, icon_id: icon.id)
      render json: icon.as_pool_row, status: :created
    else
      render json: { errors: icon.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /chores/icons/:id
  # Name + keywords only. The image itself is immutable — re-upload to
  # change it (avoids storing intermediate edit states).
  def update
    if @icon.update(icon_params.slice(:name, :keywords))
      broadcast_changed(reason: :updated, icon_id: @icon.id)
      render json: @icon.as_pool_row
    else
      render json: { errors: @icon.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /chores/icons/:id
  # Chores referencing this icon (icon: <data URL>) keep their data
  # URL intact — the value was already copied at chore-create time, so
  # nothing breaks downstream.
  def destroy
    icon_id = @icon.id
    @icon.destroy!
    broadcast_changed(reason: :destroyed, icon_id: icon_id)
    render json: { ok: true, icon_id: icon_id }
  end

  private

  def ensure_household!
    @household = current_user.chore_household
    return if @household

    respond_to do |format|
      format.html { redirect_to chores_path, alert: "Join a chore household to manage custom icons." }
      format.json { render json: { error: "no_household" }, status: :forbidden }
    end
  end

  def set_icon
    @icon = @household.icons.find(params[:id])
    return if current_user.id == @icon.uploaded_by_user_id || @household.manager?(current_user)

    render json: { error: "forbidden" }, status: :forbidden
  end

  def icon_params
    params.require(:household_icon).permit(:name, :keywords, :image_data)
  end

  def broadcast_changed(reason:, icon_id:)
    @household.member_user_ids.each do |uid|
      target = User.find_by(id: uid)
      next unless target

      MonitorChannel.broadcast_to(target, {
        id:        :chores,
        channel:   :chores,
        timestamp: Time.current.to_i,
        data:      {
          reason:        :icons_changed,
          change_reason: reason,
          icon_id:       icon_id,
          actor_user_id: current_user.id,
          actor_tab_id:  params[:tab_id],
          server_ts:     Time.current.iso8601(3),
        },
      })
    end
  end
end
