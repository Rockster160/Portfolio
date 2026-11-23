# A Live Activity the phone is showing, and the token Apple gave it for
# updates. Registering one replaces the placeholder a push-to-start left.
class Api::Ios::LiveActivitiesController < Api::Ios::BaseController
  def create
    raise ArgumentError, "activity_id is required" if params[:activity_id].blank?

    kind = params[:kind].presence || "timer"
    ref_id = params[:ref_id].to_s.presence
    AppLiveActivity.for_ref(kind, ref_id).where(app_device: current_device, push_token: nil).where(
      "activity_id LIKE 'pts:%'",
    ).delete_all

    activity = AppLiveActivity.find_or_initialize_by(activity_id: params[:activity_id].to_s)
    activity.update!(
      app_device: current_device,
      kind:       kind,
      ref_id:     ref_id,
      push_token: params[:push_token].presence || activity.push_token,
      ended_at:   nil,
    )
    render(
      json:   { id: activity.activity_id, kind: activity.kind, ref_id: activity.ref_id },
      status: :created,
    )
  end

  def destroy
    activity = AppLiveActivity.where(app_device: current_device).find_by!(activity_id: params[:id])
    activity.end!
    render json: { ok: true }
  end
end
