class Jil::Methods::Keyword < Jil::Methods::Base
  # def cast(value)
  #   case value
  #   when ::Hash then ::JSON.stringify(value)
  #   when ::Array then ::JSON.stringify(value)
  #   # when ::String then value
  #   else value.to_s
  #   end
  # end

  def execute(line)
    # √ Object
    # √ Key
    # √ Value
    # √ Index
    # √ Break
    # √ Next
    # √ Item
    #   Arg
    # √ FuncReturn -- Specs!
    case line.methodname
    when :Next
      @ctx[:next] = true
      evalarg(line.arg)
    when :Break, :FuncReturn
      @ctx[:break] = true
      evalarg(line.arg)
    when :Arg then nil # No-op, this is handled within the array #splat method
    when :Item then nil # No-op, this is handled within the array #splat method
    when :Key then @ctx[:key]
    when :Index then @ctx[:index]
    when :Value, :Object then @ctx[:value]
    end
  end
end
