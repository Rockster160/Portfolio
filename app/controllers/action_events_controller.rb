class ActionEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def index
    @events = current_user.action_events.order(timestamp: :desc).page(params[:page]).per(50)
    @events = @events.query(params[:q]) if params[:q].present?

    respond_to do |format|
      format.html
      format.json { render json: @events.per(30).serialize }
    end
  end

  def calendar
    Time.use_zone(current_user.timezone) do
      @today = Time.current.to_date
      @date = safeparse_time(params[:date]).to_date.end_of_week(:sunday)
      @week = @date.then { |t| (t - 6.days)..t }
      @events = current_user.action_events.order(timestamp: :asc)
      @events = @events.query(params[:q]) if params[:q].present?
      @events = @events.where(timestamp: @week.min.beginning_of_day..@week.max.end_of_day)

      grouped_events = @events.group_by { |evt| [evt.timestamp.to_date, evt.timestamp.hour] }
      @cal_events = [[nil, *@week]]
      (0..23).each do |hour|
        @cal_events << [hour, *@week.map { |day| grouped_events[[day, hour]] }]
      end
    end
  end

  def pullups
    Time.use_zone(current_user.timezone) do
      @today = Time.current.to_date
      @date = safeparse_time(params[:date]).to_date

      @month = @date.then { |t| t.beginning_of_month..t.end_of_month }

      @events = current_user.action_events.where(event_name: "Pullups").order(timestamp: :asc)
      @events = @events.query(params[:q]) if params[:q].present?
      @events = @events.where(timestamp: @month.min.beginning_of_day..@month.max.end_of_day)

      grouped_events = @events.group_by { |evt| evt.timestamp.to_date }
      @month_data = @month.each_with_object({}) { |date, obj| obj[date] = grouped_events[date] }

      @chart_data = {
        labels: @month_data.map { |date, evts| date.strftime("%a %-m/%-d/%y") },
        datasets: [{
          data: @month_data.map { |date, evts| evts&.sum { |evt| evt.notes.to_i } || 0 },
          backgroundColor: "#0160FF",
        }]
      }

      if @date == @today
        days_left = @date.end_of_month - @today + 1 # +1 to include today
      else
        days_left = 0
      end

      goal = 1000
      current = @events.sum("notes::integer")
      remaining = goal - current
      @stats = {
        remaining: remaining,
        current: current,
        goal: goal,
        daily_need: days_left > 0 ? remaining / days_left.to_f : 0,
      }
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
    ActionEventBroadcastWorker.perform_async(@event.id, false)
  end

  def destroy
    event = current_user.action_events.find(params[:id])

    unless event.destroy
      flash[:alert] = "Failed to destroy event."
    end

    # Reset following event streak info
    matching_events = ActionEvent
      .where(user_id: event.user_id)
      .ilike(event_name: event.event_name)
      .where.not(id: event.id)
    following = matching_events.where("timestamp > ?", event.timestamp).order(:timestamp).first
    UpdateActionStreak.perform_async(following.id) if following.present?
    # / streak info

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
