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
    when :print
      evalarg(line.arg).tap { |str|
        @jil.ctx[:output] << ::Jil::Methods::String.new(@jil, @ctx).cast(str).gsub(/^"|"$/, "")
      }
    when :presence
      val = evalarg(line.arg).presence
      case val
      when Date then val.year.positive?
      end
    when :block then evalargs(line.arg).last
    when :comment then evalarg(line.arg)
    when :loop then @jil.enumerate_loop { |ctx| evalarg(line.arg, ctx) }
    when :times
      @jil.enumerate_array(0...evalarg(line.args.first), :map) { |ctx|
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
    else send(line.methodname, *evalargs(line.args))
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
      return recurse ? looksLike(json, false) : :String
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

  def splatParams(line)
    array = @jil.input_data&.dig(:params)
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

  def del_cache(key, var)
    if var.blank?
      @jil.user.caches.find_by(key: key)&.destroy
    else
      c = @jil.user.caches.find_by(key: key)
      if c.present?
        data = c.data || {}
        data.delete(var.to_s)
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

  def commandAt(date, text)
    ::Jil::Schedule.add_schedule(@jil.user, date, :command, { words: text })
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

  def relay(contact, data)
    friend = @jil.user.contacts.name_find(contact)&.friend if contact.is_a?(::String)
    friend ||= @jil.user.contacts.find_by(id: contact[:id])&.friend if contact.is_a?(::Hash)

    return if friend&.contacts&.where(friend_id: @jil.user.id, permit_relay: true).blank?

    ::Jil.trigger_now(friend, :relay, @jil.cast(data, :Hash).merge(from: @jil.user.username))
    nil
  end

  def triggerNow(scope, data)
    ::Jil.trigger_now(@jil.user, scope, data).map(&:serialize_with_execution)
  end

  def triggerWith(scope, date, data)
    ::Jil::Schedule.add_schedule(@jil.user, date, scope, @jil.cast(data, :Hash))
  end

  def trigger(scope, date, data)
    ::Jil::Schedule.add_schedule(@jil.user, date, scope, @jil.cast(data, :Hash))
  end

  # times(Numeric content(["Break"::Any "Next"::Any "Index"::Numeric]))::Numeric
end
