class Jarvis::Execute::Text < Jarvis::Execute::Executor
  def cast
    cast_str(args)
  end

  def match
    # TODO: Allow flags
    str, reg = args.first(2).map { |t| cast_str(t) }
    return str == reg if str.blank? || reg.blank?

    reg = matchable(reg)
    if reg.is_a?(Regexp)
      flags = args[2]
      str.match?(reg)
    else
      str.include?(reg)
    end
  end

  def scan
    str, reg = args.first(2).map { |t| cast_str(t) }
    return "" if str.blank? || reg.blank?

    reg = matchable(reg)
    if reg.is_a?(Regexp)
      str.scan(reg).flatten.first
    else
      str[reg]
    end
  end

  def split
    str, split_str = args.map { |t| cast_str(t) }

    str.split(matchable(split_str))
  end

  def format
    str, cmd = args.map { |t| cast_str(t) }
    preformat = str.gsub(/[^\w\s]/, " ").gsub(/\s+/, "_").gsub(/^_*|_*$/, "")
    case cmd.to_sym
    when :lower   then str.downcase
    when :upper   then str.upcase
    when :squish  then str.squish
    when :capital then str.capitalize
    when :pascal  then preformat.camelize(:upper)
    when :title   then str.titleize
    when :snake   then preformat.underscore
    when :camel   then preformat.camelize(:lower)
    when :base64  then Base64.urlsafe_encode64(str)
    end
  end

  def replace
    original, rx, replace = evalargs
    cast_str(original).gsub(matchable(rx), replace.to_s)
  end

  private

  def matchable(reg)
    reg = cast_str(reg)
    if reg.match?(/^\s*\//) && reg.match?(/\/\w*\s*$/)
      flag_str = reg[/\w+\s*$/].to_s
      flags = 0
      flags |= Regexp::MULTILINE if flag_str.include?("m")
      flags |= Regexp::IGNORECASE if flag_str.include?("i")
      Regexp.new(reg.gsub(/^\s*\/|\/\w*\s*$/, ""), flags)
    else
      reg
    end
  end

  def cast_str(val)
    ::Jarvis::Execute::Raw.str(eval_block(val))
  end
end
