class ActionEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    @events = current_user.action_events
    @events = @events.query(params[:q]) if params[:q].present?
    @events = @events.where(user: current_user)
    @events = @events.order(timestamp: :desc).page(params[:page]).per(50)

    serialize @events
  end

  def calendar
    Time.use_zone(current_user.timezone) do
      @today = Time.current.to_date
      @date = safeparse_time(params[:date]).to_date.end_of_week(:sunday)
      @week = @date.then { |t| (t - 6.days)..t }
      @events = current_user.action_events
      @events = @events.query(params[:q]) if params[:q].present?
      @events = @events.where(user: current_user)
      @events = @events.order(timestamp: :asc)
      @events = @events.where(timestamp: @week.min.beginning_of_day..@week.max.end_of_day)

      grouped_events = @events.group_by { |evt| [evt.timestamp.to_date, evt.timestamp.hour] }
      @cal_events = [[nil, *@week]]
      (0..23).each do |hour|
        @cal_events << [hour, *@week.map { |day| grouped_events[[day, hour]] }]
      end
    end
  end

  def feelings
    Time.use_zone(current_user.timezone) do
      @today = Time.current.to_date

      if params[:start_date].present? && params[:end_date].present?
        @date = start_date = safeparse_time(params[:start_date]).to_date
        end_date = safeparse_time(params[:end_date]).to_date
        @range = (start_date.beginning_of_month..end_date.end_of_month)
      else
        @date = safeparse_time(params[:date]).to_date
        @range = @date.then { |t| t.beginning_of_month..t.end_of_month }
      end

      @events = current_user.action_events.where(name: "Feeling").order(timestamp: :asc)
      @events = @events.where(timestamp: @range)
      @chart_data = @events.map { |evt| { id: evt.id, timestamp: evt.timestamp.to_i, data: evt.data } }
    end
  end

  def pullups
    Time.use_zone(current_user.timezone) do
      @today = Time.current.to_date
      goal = 1000

      if params[:start_date].present? && params[:end_date].present?
        @date = start_date = safeparse_time(params[:start_date]).to_date
        end_date = safeparse_time(params[:end_date]).to_date
        @range = (start_date.beginning_of_month..end_date.end_of_month)
      else
        @date = safeparse_time(params[:date]).to_date
        @range = @date.then { |t| t.beginning_of_month..t.end_of_month }
      end

      @events = current_user.action_events
      @events = @events.query(params[:q]) if params[:q].present?
      @events = @events.where(user: current_user)
      @events = @events.where(timestamp: @range.min.beginning_of_day..@range.max.end_of_day)
      @events = @events.where(name: "Pullups").order(timestamp: :asc)

      grouped_events = @events.group_by { |evt| evt.timestamp.to_date }
      @range_data = @range.each_with_object({}) { |date, obj| obj[date] = grouped_events[date] }

      months = {}.tap { |month_hash|
        current_date = @range.first
        while current_date <= @range.last
          month_hash[current_date.strftime("%Y-%m")] = {
            goal: goal,
            days: 1+Time.days_in_month(current_date.month, current_date.year),
          }
          current_date = current_date.next_month
        end
      }
      @chart_data = {
        labels: @range_data.map { |date, evts| date.strftime("%a %-m/%-d/%y") },
        datasets: [
          {
            data: @range_data.map.with_index { |(date, evts), idx|
              next if date > @today

              month_data = months[date.strftime("%Y-%m")]
              days_in_month = (month_data[:days] -= 1)
              remaining_goal = month_data[:goal]
              month_data[:goal] -= (evts&.sum { |evt| evt.notes.to_i } || 0)

              next remaining_goal if days_in_month.zero?
              (remaining_goal / days_in_month).clamp(0, goal)
            },
            type: :line,
            borderColor: "rgba(255, 160, 1, 0.5)",
            backgroundColor: "rgba(255, 160, 1, 0.5)",
          },
          {
            data: @range_data.map { |date, evts| evts&.sum { |evt| evt.notes.to_i } || 0 },
            backgroundColor: "#0160FF",
          },
        ]
      }

      if @date == @today
        days_left = @date.end_of_month - @today
      else
        days_left = 0
      end

      current = @events.where("notes ~ '\\d+'").sum("notes::integer")
      total_goal = months.length*goal
      total_remaining = total_goal - current
      @stats = {
        remaining: total_remaining,
        current: current,
        goal: total_goal,
        daily_need: days_left > 0 ? total_remaining / days_left.to_f : 0,
      }
    end
  end

  def create
    event = ActionEvent.create(event_params)
    ::Jil.trigger(current_user, :event, event.with_jil_attrs(action: :added))
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
    ::Jil.trigger(current_user, :event, @event.with_jil_attrs(action: :changed))
    ActionEventBroadcastWorker.perform_async(@event.id, false)
  end

  def destroy
    event = current_user.action_events.find(params[:id])

    if event.destroy
      ::Jil.trigger(current_user, :event, event.with_jil_attrs(action: :removed))
    else
      flash[:alert] = "Failed to destroy event."
    end

    # Reset following event streak info
    matching_events = ActionEvent
      .where(user_id: event.user_id)
      .ilike(name: event.name)
      .where.not(id: event.id)
    following = matching_events.where("timestamp > ?", event.timestamp).order(:timestamp).first
    UpdateActionStreak.perform_async(following.id) if following.present?
    # / streak info

    ActionEventBroadcastWorker.perform_async
    ::RecentEventsBroadcast.call if event.present?
    redirect_to request.referrer || action_events_path
  end

  private

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
    params.to_unsafe_h.slice(:name, :timestamp, :notes, :data).tap do |whitelist|
      (params[:event_name].presence || params.dig(:action_event, :event_name)).presence&.tap { |name|
        whitelist[:name] ||= name
      }
      whitelist.delete(:data).presence&.tap { |data|
        raw_json = Tokenizer.tokenize(data.to_s, only: { "\"" => "\"" }) { |str|
          str.gsub(/\n?\s*(\w+):/) { |found|
            key = Regexp.last_match[1]
            key.match?(/__TOKEN\d+__/) ? found : " \"#{key}\":"
          }
        }
        json = BetterJsonSerializer.load(raw_json)
        if json.is_a?(::Hash) || json.is_a?(::Array)
          whitelist[:data] = json
        end
      }
    end
  end

  def form_event_params
    params.require(:action_event).permit(
      :name,
      :notes,
      :timestamp,
      :data,
    ).tap do |whitelist|
      (params[:event_name].presence || params.dig(:action_event, :event_name)).presence&.tap { |name|
        whitelist[:name] ||= name
      }
      whitelist[:timestamp] = whitelist[:timestamp].presence || Time.current
    end
  end
end
