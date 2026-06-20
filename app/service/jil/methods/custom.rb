class Jil::Methods::Custom < Jil::Methods::Base
  def cast(value)
    value
  end

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case method_sym
    when :distance
      if @jil.user.me?
        from, to, at = evalargs(line.args)
        return @jil.user.address_book.traveltime_seconds(to, from.presence, at: at.presence)
      end
    when :refresh_travel_time
      return refresh_travel_time(evalargs(line.args).first)
    end

    task = @jil.user.tasks.active.enabled.functions.by_method_name(line.methodname).take
    raise ::Jil::ExecutionError, "Undefined Method #{line.methodname}" if task.blank?

    input_data = build_function_params(line.args)
    task.execute(
      input_data, broadcast_task: @jil.broadcast_task,
      auth: :exec, auth_id: @jil.task&.id, trigger_scope: :exec
    )&.result
  end

  # Force a re-resolve of an event's location + drive time and re-run the
  # day's chain detection. User's Jil task calls this at whatever cadence
  # they like (e.g. 15 min before leave) — no scheduling assumptions here.
  def refresh_travel_time(item_ref)
    item = resolve_agenda_item(item_ref)
    return nil unless item

    ::AgendaTravelChain.refresh_for(item)
    item.reload
    item.metadata["travel"] || {}
  end

  private

  def resolve_agenda_item(value)
    return value if value.is_a?(::AgendaItem)

    hash = @jil.cast(value, :Hash)
    id = hash[:id] || hash["id"]
    return nil if id.blank?

    ::AgendaItem.locate_for_user(id, @jil.user)
  end

  def build_function_params(args)
    content = args.flatten.select { |a| a.is_a?(::Jil::Parser) }
    named_args = content.select { |p|
      p.objname == :Keyword && p.methodname.to_s.match?(/\A[a-z_]/)
    }

    if named_args.present? && named_args.length == content.length
      named_args.each_with_object({}) { |parser, hash|
        hash[parser.methodname.to_s] = @jil.execute_block(parser)
      }
    else
      { params: evalargs(args) }
    end
  end
end
