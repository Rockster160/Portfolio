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
    when :input_data then @jil.ctx[:input_data]
    when :params then @jil.ctx.dig(:input_data, :params)
    when :functionParams then splatParams(line)
    when :exit then @jil.ctx[:state] = :exit
    when :return
      @jil.ctx[:state] = :return
      @jil.ctx[:return_val] = evalarg(line.arg)
    when :if, :ternary then logic_if(*line.args)
    when :print
      evalarg(line.arg).tap { |str|
        @jil.ctx[:output] << ::Jil::Methods::String.new(@jil, @ctx).cast(str).gsub(/^"|"$/, "")
      }
    when :presence then evalarg(line.arg).presence
    when :block then evalargs(line.arg).last
    when :comment then evalarg(line.arg)
    when :loop then @jil.enumerate_loop { |ctx| evalarg(line.arg, ctx) }
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
    else send(line.methodname, *evalargs(line.args))
    end
  end

  def logic_if(condition, do_result, else_result)
    evalarg(condition) ? evalarg(do_result) : evalarg(else_result)
  end

  def splatParams(line)
    array = @jil.ctx.dig(:input_data, :params)
    line.args.flatten.map.with_index { |arg, idx|
      @jil.cast(array[idx], arg.cast).tap { |val|
        set_value(arg.varname, val, type: arg.cast)
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

  def get(var)
    @jil.ctx.dig(:vars, var.to_s.to_sym, :value)
  end

  def set!(var, val)
    set_value(var, val)
  end

  def command(text)
    ::Jarvis.command(@jil.user, text)
  end

  def commandAt(date, text)
    ::JarvisWorker.perform_at(date, @jil.user, text)
  end

  def broadcast_websocket(channel, data)
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
        ::RestClient.send(method.to_s.downcase,
          url,
          @jil.cast(params.presence || {}, :Hash).to_json,
          @jil.cast(headers.presence || {}, :Hash),
        )
      end
    )
    body = res.body
    body = ::JSON.parse(body) rescue body if res.headers[:content_type]&.match?(/json/)

    {
      code: res.code,
      headers: res.headers,
      body: body,
    }
  end

  def relay(contact, data)
    friend = @jil.user.contacts.name_find(contact)&.friend if contact.is_a?(::String)
    friend ||= @jil.user.contacts.find_by(id: contact[:id])&.friend if contact.is_a?(::Hash)

    return unless friend&.contacts&.where(friend_id: @jil.user.id, permit_relay: true)&.present?

    ::Jil::Executor.trigger(friend, :relay, @jil.cast(data, :Hash).merge(from: @jil.user.username))
    nil
  end

  def triggerNow(scope, data)
    ::Jil::Executor.trigger(@jil.user, scope, data)
  end

  def triggerWith(scope, date, data)
    ::Jil::Executor.async_trigger(@jil.user, scope, data, at: date)
  end

  def trigger(scope, date, data)
    ::Jil::Executor.async_trigger(@jil.user, scope, @jil.cast(data, :Hash), at: date)
  end

  # times(Numeric content(["Break"::Any "Next"::Any "Index"::Numeric]))::Numeric
end
