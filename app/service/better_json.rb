# {hello: :world, a: [1, 2, 3], b: { c: [], d: {e: "f", g: :h, i: [{j: :k}, {L: [:m, 9, "o"]}]}}}.better
# {}.better.pretty

module FancyRenderJson
  module_function

  INDENT = "  ".freeze
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

  def display(hash)
    puts pretty(hash)
  end

  def format(obj, depth=nil)
    case obj
    when String then "\"#{obj}\"".colorize(COLOR_MAP[:string])
    when Symbol then ":#{obj}".colorize(COLOR_MAP[:symbol])
    when TrueClass, FalseClass then obj.to_s.colorize(COLOR_MAP[:boolean])
    when Numeric then obj.to_s.colorize(COLOR_MAP[:numeric])
    when NilClass then "nil".colorize(COLOR_MAP[:null])
    when Date, Time then obj.to_s.colorize(COLOR_MAP[:date])
    when Array
      "[#{obj.map { |v| format(v, depth) }.join(", ")}]"
    when Hash, BetterJson
      return pretty(obj, depth) unless depth.nil?

      "{" + obj.map { |k,v|
        "#{k.to_s.colorize(COLOR_MAP[:key])}: #{format(v)}"
      }.join(", ") + "}"
    else
      "???<#{obj}|#{obj.class}>???".colorize(COLOR_MAP[:unknown])
    end
  end

  def pretty(hash, depth=0)
    curdent = INDENT*depth

    [
      "{",
      *hash.map { |k, v| "#{INDENT}#{k.to_s.colorize(COLOR_MAP[:key])}: #{format(v, depth+1)}," },
      "}"
    ].join("\n#{curdent}")
  end
end

class BetterJson
  attr_accessor :hash

  # ===== Hacky overwrite methods
  # Allow dot access for nested keys
  def method_missing(method, *args, &block)
    if @hash.key?(method.to_s.to_sym)
      @hash[method.to_s.to_sym]
    else
      @hash.send(method, *args, &block)
    end
  end

  # Quack like a class that inherits from Hash
  def is_a?(klass)
    klass == BetterJson || @hash.is_a?(klass)
  end

  def to_h
    @hash
  end

  def pretty
    FancyRenderJson.pretty(@hash)
  end

  # Use "key: val" syntax instead of ":key => val"
  def to_s
    pretty.uncolor.gsub(/(\s*\n)+/, " ").gsub(/\s{2,}/, " ")
  end

  # Use "key: val" syntax instead of ":key => val" + colors!
  def inspect
    pretty.uncolor
  end

  # Quack like a hash
  delegate(
    :to_json,
    :as_json,
    to: :hash
  )
  # / ===== Hacky overwrite methods

  def initialize(*args)
    @hash = HashWithIndifferentAccess.new(*args)
  end

  # Break into dot keys to value
  def branches(branchobj=nil)
    branchobj ||= self
    return branchobj unless branchobj.is_a?(Hash) || branchobj.is_a?(Array)
    return branchobj if branchobj.is_a?(Hash) && branchobj.none? { |k, v| v.is_a?(Hash) }

    # Hash with hashes
    if branchobj.is_a?(Array)
      branchobj = branchobj.each_with_index.with_object({}) do |(bval, idx), obj|
        obj["#{idx}"] = bval
      end
    end
    branchobj.each_with_object({}) do |(k, v), obj|
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

# class Hash
#   def better
#     JSON.parse(self.to_json, object_class: BetterJson)
#   end
# end
# class Array
#   def better
#     JSON.parse(self.to_json, object_class: BetterJson)
#   end
# end
