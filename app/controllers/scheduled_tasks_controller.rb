class ScheduledTasksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    @events = ::Jarvis::Schedule.get_events.sort_by { |evt| evt[:scheduled_time] || ::DateTime.new }

    respond_to do |format|
      format.html
      format.json { render json: @events.as_json }
    end
  end

  def create
    @event = event_params
    ::Jarvis::Schedule.schedule(@event)

    sleep 0.5
    respond_to do |format|
      format.json { head :ok }
      format.html { redirect_to scheduled_tasks_path }
    end
  end

  def update
    @event = ::Jarvis::Schedule.get_events(current_user).find { |event| event[:uid] == params[:uid] }
    ::Jarvis::Schedule.schedule(@event.merge!(event_params))

    sleep 0.5
    respond_to do |format|
      format.json { head :ok }
      format.html { redirect_to scheduled_tasks_path }
    end
  end

  def destroy
    @event = ::Jarvis::Schedule.get_events(current_user).find { |event| event[:uid] == params[:uid] }
    ::Jarvis::Schedule.cancel(@event[:jid])

    sleep 0.5
    respond_to do |format|
      format.json { head :ok }
      format.html { redirect_to scheduled_tasks_path }
    end
  end

  private

  def safeparse_time(time)
    return Time.current if time.blank?

    if time.is_a?(String)
      begin
        Time.use_zone(current_user.timezone) { Time.parse(time) }
      rescue StandardError
        return Time.current
      end
    else
      time
    end
  end

  def event_params
    params.to_unsafe_h.slice(
      # :uid,
      :name,
      :command,
      :scheduled_time,
      # :user_id,
      # :type,
    ).tap do |whitelist|
      whitelist[:user_id] = current_user.id
      whitelist[:scheduled_time] = safeparse_time(whitelist[:scheduled_time]) if whitelist.key?(:scheduled_time)
    end
  end
end
