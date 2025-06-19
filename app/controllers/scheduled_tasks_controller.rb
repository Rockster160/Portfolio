class ScheduledTasksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    @events = current_user.scheduled_triggers.not_started.order(execute_at: :asc).page(params[:page]).per(50)
    # @events = @events.query(params[:q]) if params[:q].present?

    serialize @events
  end

  def create
    event = current_user.scheduled_triggers.create!(event_params)
    ::Jil::Schedule.update(event) # Schedules the job
    ::Jil::Schedule.broadcast(event, :created)

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
    event = current_user.scheduled_triggers.find(params[:id])
    event.update(event_params)
    ::Jil::Schedule.update(event)
    ::Jil::Schedule.broadcast(event, :updated)
  end

  def destroy
    current_user.scheduled_triggers.find_by(id: params[:id])&.tap { |event|
      ::Jil::Schedule.cancel(event)
      event.destroy
      ::Jil::Schedule.broadcast(event, :canceled)
    }

    redirect_to request.referrer || action_events_path
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
    (params[:action_event] || params).to_unsafe_h.slice(:name, :trigger, :execute_at, :data).tap do |whitelist|
      whitelist[:execute_at] = safeparse_time(whitelist[:execute_at])
      whitelist.delete(:data).presence&.tap { |json|
        json = json.to_s.gsub(/\n?\s*(\w+):/, ' "\1":')
        json = BetterJsonSerializer.load(json)
        if json.is_a?(::Hash) || json.is_a?(::Array)
          whitelist[:data] = json
        end
      }
    end
  end

end
