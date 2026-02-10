class Jil::Methods::Task < Jil::Methods::Base
  def cast(value)
    case value
    when ::Task then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else ::SoftAssign.call(::Task.new, @jil.cast(value, :Hash))
    end
  end

  def find(id)
    @jil.user.tasks.active.find_by(id: id)
  end

  def search(q, limit, order)
    # id
    # code
    # cron
    # enabled
    # listener
    # name
    # next_trigger_at
    # uuid
    limit = (limit.presence || 50).to_i.clamp(1..100)
    scoped = @jil.user.tasks.active.page(1).per(limit)
    scoped = scoped.where(user: @jil.user)

    scoped = scoped.enabled.where.not(next_trigger_at: nil) # TODO: Allow `q` to modify this filter

    scoped = scoped.order(next_trigger_at: order) if [:asc, :desc].include?(order.to_s.downcase.to_sym)
    scoped
  end

  def id(task_data)
    task(task_data).id
  end

  def name(task_data)
    task(task_data).name
  end

  def uuid(task_data)
    task(task_data).uuid
  end

  def next_trigger_at(task_data)
    task(task_data).next_trigger_at
  end

  private

  def task(task_data)
    return task_data if task_data.is_a?(::Task)

    @jil.user.tasks.active.find_by(id: cast(task_data)[:id])
  end
end
