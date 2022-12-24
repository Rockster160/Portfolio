class ActionEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def index
    @events = current_user.action_events.order(timestamp: :desc).page(params[:page]).per(50)
    @events = @events.search(params[:q]) if params[:q].present?

    respond_to do |format|
      format.html
      format.json { render json: @events.per(30).serialize }
    end
  end

  def create
    event = ActionEvent.create(event_params)
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

  def update
    @event = ActionEvent.find(params[:id])

    @event.update(event_params)
    ActionEventBroadcastWorker.perform_async
  end

  def destroy
    event = current_user.action_events.find(params[:id])

    unless event.destroy
      flash[:alert] = "Failed to destroy event."
    end

    ActionEventBroadcastWorker.perform_async
    redirect_to action_events_path
  end

  private

  def safeparse_time(time)
    return Time.current if time.blank?

    if time.is_a?(String)
      begin
        return Time.parse(time)
      rescue StandardError
        return Time.current
      end
    else
      time
    end
  end

  def event_params
    if params.key?(:action_event)
      prepared_params = form_event_params
    else
      prepared_params = raw_event_params
    end

    prepared_params.merge!(user: current_user)

    prepared_params.tap { |whitelist|
      if whitelist[:notes].to_s.match?(/^(\-|\+)\d+/)
        offset_time = whitelist[:notes][/^(\-|\+)\d+/].to_i
        whitelist[:notes] = whitelist[:notes].sub(/^(\-|\+)\d+ ?/, "")
        time = safeparse_time(whitelist[:timestamp])
        whitelist[:timestamp] = time + offset_time.minutes
      end
    }
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
