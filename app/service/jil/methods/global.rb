class Jil::Methods::Global < Jil::Methods::Base
  # def cast(value)
  #   case value
  #   when ::Hash then ::JSON.stringify(value)
  #   when ::Array then ::JSON.stringify(value)
  #   # when ::String then value
  #   else value.to_s
  #   end
  # end

  def execute(line)
    case line.methodname
    when :input_data then @jil.input_data
    when :params then @jil.input_data&.dig(:params)
    when :functionParams then splatParams(line)
    when :exit then @jil.ctx[:state] = :exit
    when :return
      @jil.ctx[:state] = :return
      @jil.ctx[:return_val] = evalarg(line.arg)
    when :if, :ternary then logic_if(*line.args)
    when :case then logic_case(*line.args)
    when :try then logic_try(*line.args)
    when :print
      evalarg(line.arg).tap { |str|
        @jil.ctx[:output] << ::Jil::Methods::String.new(@jil, @ctx).cast(str).gsub(/^"|"$/, "")
      }
    when :presence
      evalarg(line.arg).presence
    when :block then evalargs(line.arg).last
    when :comment then evalarg(line.arg)
    when :loop then @jil.enumerate_loop { |ctx| evalarg(line.arg, ctx) }
    when :times
      @jil.enumerate_array(0...@jil.cast(evalarg(line.args.first), :Numeric), :map) { |ctx|
        evalarg(line.args.last, ctx)
      }
    when :dowhile
      @jil.enumerate_loop { |ctx|
        val = evalarg(line.arg, ctx)
        break val if val
      }
    # when :get, :set! then send(line.methodname, *line.args)
    when :stop_propagation then @jil.ctx[:stop_propagation] = true
    when :function
      args, content = line.args
      { args: evalarg(args), content: content.map { |line| line.to_s.squish }.join("\n") }
    else
      raise ::Jil::ExecutionError, "Undefined Global method: #{line.methodname}" unless respond_to?(line.methodname)

      send(line.methodname, *evalargs(line.args))
    end
  end

  def looksLike(str, recurse: true)
    case str
    when Hash                  then return :Hash
    when Array                 then return :Array
    when TrueClass, FalseClass then return :Boolean
    when NilClass              then return :None
    when Numeric               then return :Numeric
    when Date, Time, DateTime  then return :Date
    end

    str = str.to_s
    begin
      json = ::Jil::Methods::Hash.parse(str)
      return recurse ? looksLike(json, recurse: false) : :String
    rescue StandardError => e
    end
    return :Boolean if ["true", "false", "t", "f"].include?(str.downcase)

    return :Numeric if Integer(str) rescue false
    return :Numeric if Float(str) rescue false
    # FIXME: "'6'" is considered a date because it looks like '6
    return :Date if Date.parse(str) rescue false
    return :Date if Time.zone.parse(str) rescue false
    :String
  end

  def logic_if(condition, do_result, else_result)
    evalarg(condition) ? evalarg(do_result) : evalarg(else_result)
  end

  def logic_case(value, when_blocks)
    eval_val = evalarg(value)
    else_block = nil
    Array.wrap(when_blocks).each do |when_block|
      if when_block.methodname == :Else
        else_block = when_block.args.first
        next
      end
      match_val, content = when_block.args
      evaluated_match = evalarg(match_val)
      if evaluated_match == "else"
        else_block = content
        next
      end
      if evaluated_match.is_a?(::String) && evaluated_match.match?(/^\s*\/.*?\/[img]*\s*$/)
        pattern = evaluated_match[/^\s*\/(.*?)\/[img]*\s*$/, 1]
        flags = evaluated_match[/\/([img]*)\s*$/, 1].to_s
        rx_flags = 0
        rx_flags |= Regexp::IGNORECASE if flags.include?("i")
        rx_flags |= Regexp::MULTILINE if flags.include?("m")
        return evalarg(content) if eval_val.to_s.match?(Regexp.new(pattern, rx_flags))
      elsif evaluated_match == eval_val || @jil.cast(evaluated_match) == @jil.cast(eval_val)
        return evalarg(content)
      end
    end
    evalarg(else_block) if else_block
  end

  def logic_try(try_block, catch_block)
    evalarg(try_block)
  rescue StandardError => e
    set_value(:error, e.message, type: :String)
    evalarg(catch_block)
  end

  def splatParams(line)
    pos_idx = 0
    line.args.flatten.map { |arg|
      val = if arg.is_a?(::Jil::Parser) && arg.methodname == :NamedArg
        key = evalarg(arg.args.first)
        @jil.input_data&.dig(key)
      else
        @jil.input_data&.dig(:params)&.at(pos_idx).tap { pos_idx += 1 }
      end
      @jil.cast(val, arg.cast).tap { |casted|
        set_value(arg.varname, casted, type: arg.cast)
      }
    }.compact
  end

  def get_cache(key, var)
    @jil.user.caches.dig(key, var)
  end

  # def dig_cache(key, var)
  #   @jil.user.caches.dig(key, var)
  # end

  def set_cache(key, var, val)
    @jil.user.caches.dig_set(*([key, var].compact_blank), val) && val
  end

  def del_cache(key, var)
    if var.blank?
      @jil.user.caches.find_by(key: key)&.destroy
    else
      c = @jil.user.caches.find_by(key: key)
      if c.present?
        data = c.data || {}
        data.delete(var.to_s)
        data.delete(var.to_s.to_sym)
        c.update(data: data)
      end
    end
    true
  end

  def ref(var)
    var
  end

  def get(var)
    @jil.ctx.dig(:vars, var.to_s.to_sym, :value)
  end

  def set!(var, val)
    set_value(var, val)
  end

  def command(text)
    ::Jarvis.command(@jil.user, text)
  end

  def ping(text, at=nil)
    broadcast_or_schedule(text, :ping, at: at)
  end

  def say(text, at=nil)
    broadcast_or_schedule(text, :ws, at: at)
  end

  def textMe(text, at=nil)
    broadcast_or_schedule(text, :sms, at: at)
  end

  def remind(text, at=nil)
    broadcast_or_schedule(text, :ping, at: at, add_to_list: true)
  end

  private def broadcast_or_schedule(text, channel, at: nil, add_to_list: false)
    if at.present?
      ::Jil::Schedule.add_schedule(
        @jil.user, at, :broadcast,
        { text: text, channel: channel, add_to_list: add_to_list }.compact,
        auth: :trigger, auth_id: @jil.task&.id,
      )
    else
      ::Jarvis.broadcast(@jil.user, text, channel)
      @jil.user.default_list&.add_items(name: text) if add_to_list
    end
    text
  end

  def commandAt(date, text)
    ::Jil::Schedule.add_schedule(
      @jil.user, date, :command, { words: text },
      auth: :trigger, auth_id: @jil.task&.id
    )
  end

  def broadcast_websocket(channel, data)
    ::JarvisChannel.broadcast(data: data) if channel == "Jarvis" && @jil.user == User.me
    ::SocketChannel.send_to(@jil.user, channel, data)
  end

  def request(method, url, params, headers)
    # TODO: Support different content-types
    res = (
      case method.to_s.upcase.to_sym
      when :GET
        ::RestClient.get(
          url,
          @jil.cast(headers.presence || {}, :Hash).merge(params: params),
        )
      when :POST, :PATCH, :PUT, :DELETE
        ::RestClient.send(
          method.to_s.downcase,
          url,
          @jil.cast(params.presence || {}, :Hash).to_json,
          @jil.cast(headers.presence || {}, :Hash),
        )
      end
    )
    body = res.body
    body = ::JSON.parse(body) rescue body if res.headers[:content_type]&.match?(/json/)

    {
      code:    res.code,
      headers: res.headers,
      body:    body,
    }
  end

  def requestBody(url, params, headers)
    res = ::RestClient::Request.execute(
      method:  :get,
      url:     url,
      payload: @jil.cast(params.presence || {}, :Hash).to_json,
      headers: @jil.cast(headers.presence || {}, :Hash).merge(content_type: :json),
    )
    body = res.body
    body = ::JSON.parse(body) rescue body if res.headers[:content_type]&.match?(/json/)

    {
      code:    res.code,
      headers: res.headers,
      body:    body,
    }
  end

  def triggerNow(scope, data)
    ::Jil.trigger(@jil.user, scope, data, auth: :trigger, auth_id: @jil.task&.id).map(&:serialize_with_execution)
  end

  # Resolves a Jil-side value into an AgendaItem record scoped to the
  # current user. Accepts the record itself, a serialized hash (the shape
  # the agenda_item Jil trigger fires with), or anything castable to
  # Hash with an :id key. Returns nil if the row can't be reached.
  private def resolve_source_item(value)
    return value if value.is_a?(::AgendaItem)

    hash = @jil.cast(value, :Hash)
    id = hash[:id] || hash["id"]
    return nil if id.blank?

    ::AgendaItem.locate_for_user(id, @jil.user)
  end

  OFFSET_UNIT_SECONDS = {
    "second" => 1, "seconds" => 1,
    "minute" => 60, "minutes" => 60,
    "hour"   => 3_600, "hours" => 3_600,
    "day"    => 86_400, "days" => 86_400,
  }.freeze

  private def compute_offset_seconds(offset, unit)
    multiplier = OFFSET_UNIT_SECONDS[unit.to_s.downcase] || 60
    @jil.cast(offset, :Numeric).to_i * multiplier
  end

  def triggerWith(scope, date, data)
    ::Jil::Schedule.add_schedule(
      @jil.user, date, scope, @jil.cast(data, :Hash),
      auth: :trigger, auth_id: @jil.task&.id
    )
  end

  def trigger(scope, date, data)
    ::Jil::Schedule.add_schedule(
      @jil.user, date, scope, @jil.cast(data, :Hash),
      auth: :trigger, auth_id: @jil.task&.id
    )
  end

  # Upserts a "derived" ScheduledTrigger keyed by (source_item, name). The
  # execute_at is computed from source.start_at + (offset * unit-seconds);
  # negative offsets schedule before the source, positive ones after. When
  # the source AgendaItem's start_at later moves, the AgendaItem callback
  # propagates the new execute_at automatically; when the source is
  # destroyed, the FK cascade removes this trigger.
  #
  # `name` is the rule label — pick something stable like
  # "suite-reminder" or "warm-up-car" so subsequent runs of the same Jil
  # task update the same row instead of creating duplicates.
  def trigger_for(source, name, offset, unit, scope, data)
    source_item = resolve_source_item(source)
    return nil unless source_item
    return nil if scope.blank?

    offset_secs = compute_offset_seconds(offset, unit)
    execute_at = source_item.start_at + offset_secs.seconds
    rec = @jil.user.scheduled_triggers.where(
      source_item_id: source_item.id, name: name.to_s
    ).first_or_initialize
    was_new = rec.new_record?

    rec.update!(
      trigger:        scope.to_s,
      execute_at:     execute_at,
      offset_seconds: offset_secs,
      data:           @jil.cast(data, :Hash),
      auth_type:      :trigger,
      auth_type_id:   @jil.task&.id,
    )

    ::Jil::Schedule.update(rec)
    ::Jil::Schedule.broadcast(rec, was_new ? :created : :updated)
    rec
  end

  # Tear-down counterpart to `trigger_for` — destroys the derived
  # ScheduledTrigger keyed by (source, name) if it exists. No-op when the
  # row was never created. Used by rules whose match condition no longer
  # holds (e.g. user edited the location and the suite text is gone).
  def remove_trigger_for(source, name)
    source_item = resolve_source_item(source)
    return false unless source_item

    rec = @jil.user.scheduled_triggers.find_by(
      source_item_id: source_item.id, name: name.to_s
    )
    return false unless rec

    ::Jil::Schedule.cancel(rec)
    rec.destroy.destroyed?
  end

  # times(Numeric content(["Break"::Any "Next"::Any "Index"::Numeric]))::Numeric
end
