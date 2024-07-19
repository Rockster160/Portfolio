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
    when :next then @ctx[:next] = true
    when :break then @ctx[:break] = true
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
    else send(line.methodname, line.args)
    end
  end

  def logic_if(condition, do_result, else_result)
    evalarg(condition) ? evalarg(do_result) : evalarg(else_result)
  end
end
# [Global]
# [~]   #input_data::Hash
# [~]   #return(Any?)
# [~]   #if("IF" content "DO" content "ELSE" content)::Any
# [ ]   #get(String)::Any // Variable reference
# [ ]   #set(String "=" Any)::Any
# [ ]   #get_cache(String)::Any // Could Cache.get be a non-object Class? Doesn't show up in return-types, but is still a class for organization
# [ ]   #set_cache(String "=" Any)::Any
# [~]   #exit
# [~]   #print(Text)::String
# [~]   #comment(Text)::None
# [ ]   #command(String)::String
# [ ]   #request("Method" String BR "URL" String BR "Params" Hash BR "Headers" Hash)::Hash
# [ ]   #broadcast_websocket("Channel" TAB String BR "Data" TAB Hash)::Numeric
# [ ]   #trigger(String Hash)::Numeric
# [ ]   #dowhile(content(["Break" "Next" "Index"::Numeric]))::Numeric
# [ ]   #loop(content(["Break" "Next" "Index"::Numeric]))::Numeric
# [ ]   #times(Numeric content(["Break" "Next" "Index"::Numeric]))::Numeric
# [ ]   #eval(Text) # Should return the value given by a "return" that's called inside
