class ScheduledTasksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def index
    @events = ::Jarvis::Schedule.get_events

    respond_to do |format|
      format.html
      format.json { render json: @events.as_json }
    end
  end

  def create
    @event = event_params
    binding.pry
    ::Jarvis::Schedule.schedule(@event)

    respond_to do |format|
      format.json { head :ok }
      format.html { redirect_to scheduled_tasks_path }
    end
  end

  def update
    @event = ::Jarvis::Schedule.get_events(current_user).find { |event| event[:uid] == params[:uid] }
    ::Jarvis::Schedule.schedule(@event.merge!(event_params))

    respond_to do |format|
      format.json { head :ok }
      format.html { redirect_to scheduled_tasks_path }
    end
  end

  def destroy
    @event = ::Jarvis::Schedule.get_events(current_user).find { |event| event[:uid] == params[:uid] }
    ::Jarvis::Schedule.cancel(@event[:jid])

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
        return Time.parse(time)
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
      whitelist[:scheduled_time] = safeparse_time(whitelist[:scheduled_time])
    end
  end
end
