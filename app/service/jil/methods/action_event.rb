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
    when :id, :action, *PERMIT_ATTRS
      case token_class(line.objname)
      when :ActionEvent
        token_val(line.objname)[method_sym]
      when :ActionEventData
        send(method_sym, *evalargs(line.args))
      end
    when :matches
      matches_query?(token_val(line.objname), evalarg(line.args.first))
    else fallback(line)
    end
  end

  # Evaluate a Tokenizing search query (e.g. "name::Whisper notes::Up")
  # against the given event using the same parser the .query() scope
  # uses for AR searches. Blank query returns true.
  def matches_query?(event, query)
    return false if event.nil?
    return true if query.to_s.blank?

    @jil.user.action_events.query(query.to_s).where(id: event.id).exists?
  end

  def update!(event_data, details)
    event = load_event(event_data)
    evt_data = params(details)
    event_callbacks(event, :changed, evt_data[:timestamp].present?) if event.update(evt_data)
    event
  end

  def bulk_destroy(query, limit=10_000)
    cap = (limit.presence || 10_000).to_i.clamp(1..100_000)
    batch_size = 500
    total = 0
    loop do
      remaining = cap - total
      break if remaining <= 0

      batch = [batch_size, remaining].min
      ids = events.query(query).where(user: @jil.user).limit(batch).pluck(:id)
      break if ids.empty?

      deleted = ::ActionEvent.where(user_id: @jil.user.id, id: ids).delete_all
      total += deleted
      break if deleted < batch
    end
    total
  end

  def bulk_update(query, limit, details)
    cap = (limit.presence || 10_000).to_i.clamp(1..100_000)
    attrs = params(details)
    return 0 if attrs.blank?

    ids = events.query(query).where(user: @jil.user).limit(cap).pluck(:id)
    return 0 if ids.empty?

    ::ActionEvent.where(user_id: @jil.user.id, id: ids).update_all(attrs)
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
    attrs = { action: action }
    attrs[:changes] = event.saved_changes if action == :changed && event.saved_changes.present?
    ::Jil.trigger(
      @jil.user, :event, event.with_jil_attrs(attrs),
      auth: :trigger, auth_id: @jil.task&.id
    )
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
