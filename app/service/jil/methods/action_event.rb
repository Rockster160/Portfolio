class Jil::Methods::ActionEvent < Jil::Methods::Base
  PERMIT_ATTRS = [:name, :notes, :data, :date]

  def cast(value)
    case value
    when ::ActionEvent then value.serialize
    else @jil.cast(value, :Hash)
    end
  end

  def find(id)
    events.find_by(id: id)
  end

  def search(q, limit, order)
    limit = (limit.presence || 50).to_i.clamp(1..100)
    scoped = events.query(q).page(1).per(limit)
    scoped = scoped.order(created_at: order) if [:asc, :desc].include?(order.to_s.downcase.to_sym)
    scoped.serialize
  end

  def add(name)
    events.create(name: name).tap { |event|
      event_callbacks(event, :added)
    }
  end

  def create(details)
    events.create(params(details)).tap { |event|
      event_callbacks(event, :added)
    }.serialize
  end

  def execute(line)
    case line.methodname
    when :id, *PERMIT_ATTRS
      case token_class(line.objname)
      when :ActionEvent
        token_val(line.objname)[line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym]
      when :ActionEventData
        send(line.methodname, *evalargs(line.args))
      end
    else fallback(line)
    end
  end

  def update!(event_data, details)
    events.find(event_data[:id]).tap { |event|
      evt_data = params(details)
      if event.update(evt_data)
        event_callbacks(event, :changed, evt_data[:date].present?)
      end
    }
  end

  def destroy(event_data)
    event = load_event(event_data)
    event.destroy.tap { |bool|
      if bool
        event_callbacks(event, :removed) do |removed_event|
          # Reset following event streak info
          matching_events = ActionEvent
            .where(user_id: removed_event.user_id)
            .ilike(name: removed_event.name)
            .where.not(id: removed_event.id)
          following = matching_events.where("timestamp > ?", removed_event.timestamp).order(:timestamp).first
          UpdateActionStreak.perform_async(following.id) if following.present?
        end
      end
    }
  end

  def name(text)
    { name: text }
  end

  def notes(text)
    { notes: text }
  end

  def date(date)
    { timestamp: date }
  end

  def data(details={})
    { data: details }
  end

  private

  def event_callbacks(event, action, update_streak=true, &after)
    ::Jil::Executor.async_trigger(event.user_id, :event, event.serialize.merge(action: action))
    ::Jarvis.trigger_async(event.user_id, :event, event.serialize.merge(action: action))
    after&.call(event)
    ActionEventBroadcastWorker.perform_async(event.id, update_streak)
  end

  def params(details)
    @jil.cast(details, :Hash).slice(*PERMIT_ATTRS).tap { |obj|
      obj[:data] = @jil.cast(obj[:data], :Hash)
    }
  end

  def load_event(jil_event)
    @jil.user.action_events.find(cast(jil_event)[:id])
  end

  def events
    @events ||= @jil.user.action_events.order(timestamp: :desc)
  end
end
