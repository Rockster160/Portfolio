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
    when :next, :Next
      @ctx[:next] = true
      evalarg(line.arg)
    when :break, :Break
      @ctx[:break] = true
      evalarg(line.arg)
    when :exit then @jil.ctx[:state] = :exit
    when :return
      @jil.ctx[:state] = :return
      @jil.ctx[:return_val] = evalarg(line.arg)
    when :if then logic_if(*line.args)
    when :print
      evalarg(line.arg).tap { |str|
        @jil.ctx[:output] << ::Jil::Methods::String.new(@jil, @ctx).cast(str).gsub(/^"|"$/, "")
      }
    when :comment then evalarg(line.arg)
    when :loop then @jil.enumerate_loop { |ctx| evalarg(line.arg, ctx) }
    when :dowhile
      @jil.enumerate_loop { |ctx|
        val = evalarg(line.arg, ctx)
        break val if val
      }
    when :Key then @ctx[:key]
    when :Index then @ctx[:index]
    when :Value, :Object then @ctx[:value]
    when :get, :set! then send(line.methodname, *line.args)
    else send(line.methodname, *evalargs(line.args))
    end
  end

  def logic_if(condition, do_result, else_result)
    evalarg(condition) ? evalarg(do_result) : evalarg(else_result)
  end

  def get_cache(var)
    @jil.user.caches.dig(:jil, var)
  end

  def set_cache(var, val)
    @jil.user.caches.dig_set(:jil, var, val) && val
  end

  def get(var)
    @jil.ctx[:vars][var.to_sym][:value]
  end

  def set!(var, val)
    set_value(var, evalarg(val))
  end

  def command(text)
    ::Jarvis.command(@jil.user, text)
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
    body = ::JSON.parse(body) rescue body if res.headers[:content_type].match?(/json/)

    {
      code: res.code,
      headers: res.headers,
      body: body,
    }
  end

  def trigger(scope, data)
    ::Jil::Executor.trigger(@jil.user, scope, data)
  end

  # def import
  # end

  # times(Numeric content(["Break"::Any "Next"::Any "Index"::Numeric]))::Numeric
end
