class Jarvis::Execute::Text < Jarvis::Execute::Executor
  def cast
    cast_str(eval_block(args))
  end

  def match
    # TODO: Allow flags
    str, reg = args.first(2).map { |t| cast_str(eval_block(t)) }
    return str == reg if str.blank? || reg.blank?

    if reg.starts_with?("/") && reg.match?(/\/\w*$/)
      flags = args[2]
      str.match?(/#{reg}/)
    else
      str.include?(reg)
    end
  end

  def split
    # TODO: Allow split by regex
    str, split_str = args.map { |t| cast_str(eval_block(t)) }
    str.split(split_str)
  end

  def format
    # TODO: Allow split by regex
    str, split_str = args.map { |t| cast_str(eval_block(t)) }
    str.split(split_str)
  end

  private

  def cast_str(val)
    ::Jarvis::Execute::Raw.str(val)
  end
end
