# {hello: :world, a: [1, 2, 3], b: { c: [], d: {e: "f", g: :h, i: [{j: :k}, {L: [:m, 9, "o"]}]}}}.better
# {}.better.pretty
class BetterJson
  COLOR_MAP = {
    key: :yellow,
    string: :lime,
    symbol: :orange,
    boolean: :cyan,
    numeric: :magenta,
    date: :blue,
    null: :grey,
    unknown: :red,
  }.freeze
  INDENT = "  ".freeze

  # Allow dot access for nested keys
  def method_missing(method, *args, &block)
    if @hash.key?(method.to_s.to_sym)
      @hash[method.to_s.to_sym]
    else
      @hash.send(method, *args, &block)
    end
  end

  def initialize(*args)
    @hash = HashWithIndifferentAccess.new(*args)
  end

  def colorit(obj, depth=nil)
    case obj
    when String then "\"#{obj}\"".colorize(COLOR_MAP[:string])
    when Symbol then ":#{obj}".colorize(COLOR_MAP[:symbol])
    when TrueClass, FalseClass then obj.to_s.colorize(COLOR_MAP[:boolean])
    when Numeric then obj.to_s.colorize(COLOR_MAP[:numeric])
    when NilClass then "nil".colorize(COLOR_MAP[:null])
    when Date then v.to_s.colorize(COLOR_MAP[:date])
    when Array
      "[#{obj.map { |v| colorit(v, depth) }.join(", ")}]"
    when Hash, BetterJson
      return obj.to_pretty(depth) unless depth.nil?
      "{" + obj.map { |k,v|
        "#{k.to_s.colorize(COLOR_MAP[:key])}: #{colorit(v)}"
      }.join(", ") + "}"
    else
      "???<#{obj}|#{obj.class}>???".colorize(COLOR_MAP[:unknown])
    end
  end

  def to_s
    inspect
  end

  def inspect
    colorit(@hash)
  end

  def to_pretty(depth=0)
    curdent = INDENT*depth

    [
      "{",
      *@hash.map { |k, v| "#{INDENT}#{k.to_s.colorize(COLOR_MAP[:key])}: #{colorit(v, depth+1)}" },
      "}"
    ].join("\n#{curdent}")
  end

  def pretty(depth=0)
    puts to_pretty
  end

  # Break into dot keys to value
  def branches(hash=nil)
    hash ||= self
    return hash unless hash.is_a?(Hash) || hash.is_a?(Array)
    return hash if hash.is_a?(Hash) && hash.none? { |k, v| v.is_a?(Hash) }

    # Hash with hashes
    if hash.is_a?(Array)
      hash = hash.each_with_index.with_object({}) do |(bval, idx), obj|
        obj["#{idx}"] = bval
      end
    end
    hash.each_with_object({}) do |(k, v), obj|
      next obj[k.to_s] = v if v.nil? || v == false # Falsey things will act weird in #branches

      bdata = branches(v)
      case bdata
      when Hash
        bdata.each do |bkey, bval|
          obj["#{k}.#{bkey}"] = bval
        end
      else
        obj["#{k}"] = bdata
      end
    end
  end
end

class Hash
  def better
    JSON.parse(self.to_json, object_class: BetterJson)
  end
end
