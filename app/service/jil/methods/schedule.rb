class Jil::Methods::Schedule < Jil::Methods::Base
  PERMIT_ATTRS = [:execute_at, :trigger, :data]
  def cast(value)
    case value
    when ::JilScheduledTrigger then value.serialize
    else @jil.cast(value, :Hash)
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
    case line.methodname
    when :id, *PERMIT_ATTRS
      case token_class(line.objname)
      when :Schedule
        token_val(line.objname)[line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym]
      when :ScheduleData
        send(line.methodname, *evalargs(line.args))
      end
    else fallback(line)
    end
  end

  # [Schedule]

  def find(id)
    schedules.find_by(id: id)&.serialize
  end

  def search(name)
    schedules.break_searcher(name).map(&:serialize)
  end

  def update!(schedule, details)
    schedules.find(schedule[:id])&.tap { |s|
      s.update(params(details))
      ::Jil::Schedule.update(s)
    }.serialize
  end

  def cancel!(schedule)
    schedules.find(schedule[:id])&.tap { |s|
      ::Jil::Schedule.cancel(s)
      s.destroy
    }.serialize.merge(canceled: true).except(:id)
  end

  # [ScheduleData]

  def execute_at(date)
    { execute_at: date }
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
