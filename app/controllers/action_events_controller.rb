class ActionEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def index
    @events = current_user.action_events.order(timestamp: :desc).page(params[:page]).per(50)
    @events = @events.where("event_name ILIKE ?", params[:filter]) if params[:filter].present?

    respond_to do |format|
      format.html
      format.json { render json: @events.per(30).serialize }
    end
  end

  def create
    event = ActionEvent.create(action_event_params.merge(user: current_user))
    ActionEventBroadcastWorker.perform_async(event.id)

    respond_to do |format|
      format.json do
        if event.persisted?
          head :ok
        else
          SlackNotifier.notify(event.errors.full_messages.join("\n"))
          head :unprocessable_entity
        end
      end

      format.html do
        unless event.valid?
          flash[:alert] = "Failed to create event: #{event.errors.full_messages.join(' | ')}"
        end
        redirect_to action_events_path
      end
    end
  end

  def destroy
    event = current_user.action_events.find(params[:id])

    unless event.destroy
      flash[:alert] = "Failed to destroy event."
    end

    redirect_to action_events_path
  end

  private

  def action_event_params
    if params.key?(:action_event)
      form_event_params
    else
      raw_event_params
    end
  end

  def raw_event_params
    params.to_unsafe_h.slice(:event_name, :timestamp, :notes)
  end

  def form_event_params
    params.require(:action_event).permit(
      :event_name,
      :notes,
      :timestamp,
    ).tap do |whitelist|
      whitelist[:timestamp] = whitelist[:timestamp].presence || Time.current
    end
  end
end
