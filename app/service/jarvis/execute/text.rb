class Jarvis::Execute::Text < Jarvis::Execute::Executor
  def cast
    cast_str(eval_block(args))
  end

  def match
    # TODO: Allow flags
    str, reg = args.first(2).map { |t| cast_str(eval_block(t)) }
    return false if reg.blank?

    flags = args[2]
    str.match?(/#{reg}/)
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
