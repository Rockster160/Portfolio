class Jil::Methods::ActionEvent < Jil::Methods::Base
  PERMIT_ATTRS = [:name, :notes, :data, :timestamp].freeze

  def cast(value)
    case value
    when ::Numeric then find(value)
    when ::ActionEvent then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else ::SoftAssign.call(::ActionEvent.new, @jil.cast(value, :Hash))
    end
  end

  def find(id)
    events.find_by(id: id)
  end

  def search(q, limit, order)
    limit = (limit.presence || 50).to_i.clamp(1..100)
    scoped = events.query(q).page(1).per(limit)
    scoped = scoped.where(user: @jil.user)

    order = [:asc, :desc].include?(order.to_s.downcase.to_sym) ? order.to_s.downcase.to_sym : :desc
    scoped.order(timestamp: order)
  end

  def add(name)
    events.create(name: name).tap { |event|
      event_callbacks(event, :added)
    }
  end

  def create(details)
    events.create(params(details)).tap { |event|
      event_callbacks(event, :added)
    }
  end

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case method_sym
    when :id, *PERMIT_ATTRS
      case token_class(line.objname)
      when :ActionEvent
        token_val(line.objname)[method_sym]
      when :ActionEventData
        send(method_sym, *evalargs(line.args))
      end
    else fallback(line)
    end
  end

  def update!(event_data, details)
    event = load_event(event_data)
    evt_data = params(details)
    event_callbacks(event, :changed, evt_data[:timestamp].present?) if event.update(evt_data)
    event
  end

  def destroy(event_data)
    event = load_event(event_data)
    event.destroy.tap { |bool|
      if bool
        event_callbacks(event, :removed) { |removed_event|
          # Reset following event streak info
          matching_events = ActionEvent
            .where(user_id: removed_event.user_id)
            .ilike(name: removed_event.name)
            .where.not(id: removed_event.id)
          following = matching_events.where(
            "timestamp > ?",
            removed_event.timestamp,
          ).order(:timestamp).first
          UpdateActionStreak.perform_async(following.id) if following.present?
        }
      end
    }
  end

  def name(text)
    { name: text }
  end

  def notes(text)
    { notes: text }
  end

  def timestamp(timestamp)
    return if timestamp.year.negative? # Invalid date should just leave blank

    { timestamp: timestamp }
  end

  def data(details={})
    { data: details }
  end

  private

  def event_callbacks(event, action, update_streak=true, &callback)
    ::Jil.trigger(@jil.user, :event, event.with_jil_attrs(action: action))
    callback&.call(event)
    ActionEventBroadcastWorker.perform_async(event.id, update_streak)
  end

  def params(details)
    Array.wrap(details).tap { |d|
      next unless d.length == 1 && d.first.is_a?(ActionEvent)

      return details.first.serialize.except(:id)
    }

    @jil.cast(details, :Hash).slice(*PERMIT_ATTRS).tap { |obj|
      obj[:data] = @jil.cast(obj[:data], :Hash) if obj.key?(:data)
    }
  end

  def load_event(jil_event)
    return jil_event if jil_event.is_a?(::ActionEvent)

    jil_params = cast(jil_event)
    id = jil_params[:id]
    return @jil.user.action_events.new(jil_params) if id.blank?

    @jil.user.action_events.find(id)
  end

  def events
    @events ||= @jil.user.action_events.order(timestamp: :desc)
  end
end
