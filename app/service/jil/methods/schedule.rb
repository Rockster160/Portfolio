class Jil::Methods::Schedule < Jil::Methods::Base
  PERMIT_ATTRS = [:name, :execute_at, :trigger, :data]
  def cast(value)
    case value
    when ::ScheduledTrigger then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else ::SoftAssign.call(::ScheduledTrigger.new, @jil.cast(value, :Hash))
    end
  end

  # [Schedule]
  #   #find(String|Numeric)
  #   #search # Using listener syntax trigger:word::data
  #   .update!(content(ScheduleData))
  #   .cancel!::Boolean
  #   .id::String # String or Numeric?
  #   .executeAt::Date
  #   .trigger::String
  #   .data::Hash
  # *[ScheduleData]
  #   #executeAt(Date)
  #   #trigger(String)
  #   #data(content(Hash))

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case method_sym
    when :id, *PERMIT_ATTRS
      case token_class(line.objname)
      when :Schedule
        token_val(line.objname)[method_sym]
      when :ScheduleData
        send(method_sym, *evalargs(line.args))
      end
    else fallback(line)
    end
  end

  # [Schedule]

  def find(id)
    schedules.find_by(id: id)
  end

  def search(name)
    schedules.break_searcher(name)
  end

  def create(details)
    fix_params = params(details).compact_blank.reverse_merge(execute_at: ::Time.current)
    s = @jil.user.scheduled_triggers.create!(fix_params)
    ::Jil::Schedule.update(s) # Schedules the job
    ::Jil::Schedule.broadcast(s, :created)
    s
  end

  def update!(schedule, details)
    schedules.find(schedule[:id]).tap { |s|
      s.update(params(details))
      ::Jil::Schedule.update(s)
      ::Jil::Schedule.broadcast(s, :updated)
    }
  end

  def cancel!(schedule)
    schedules.find_by(id: schedule[:id])&.tap { |s|
      ::Jil::Schedule.cancel(s)
      s.destroy
      ::Jil::Schedule.broadcast(s, :canceled)
      s.id = nil
    }&.merge(canceled: true)
  end

  # [ScheduleData]

  def execute_at(date)
    return if date.year <= 0 # Invalid date should just leave blank

    { execute_at: date }
  end

  def name(text)
    { name: text }
  end

  def trigger(text)
    { trigger: text }
  end

  def data(details={})
    { data: details }
  end

  private

  def schedules
    @jil.user.scheduled_triggers
  end

  def params(details)
    @jil.cast(details, :Hash).slice(*PERMIT_ATTRS).tap { |obj|
      obj[:data] = @jil.cast(obj[:data], :Hash) if obj.key?(:data)
    }
  end
end
