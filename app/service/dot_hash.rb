class DotHash < ::Hash
  def self.from(hash)
    case hash
    when ::Hash then new(hash)
    when ::Array then hash.map { |h| from(h) }
    else hash
    end
  end

  def self.every_stream(hash)
    from(hash).every_stream
  end

  #  IN={"event.dot\\.data.custom.nested_key"=>"fuzzy_val thing"}
  # OUT={event: {"dot.data": {custom: {nested_key: "fuzzy_val thing"}}}}
  def self.from_branch(hash)
    DotHash.new(hash).each_with_object(DotHash.new) { |(key, value), result|
      parts = key.to_s.split(/(?<!\\)\./).map { |part| part.gsub(/\\\./, ".") }
      last_key = parts.pop
      nested = parts.inject(result) { |h, k| h[k.to_sym] ||= DotHash.new }
      nested[last_key.to_sym] = DotHash.from(value)
    }
  end

  def initialize(hash={})
    super()
    hash.deep_symbolize_keys.each do |key, val|
      self[key] = DotHash.from(val)
    end
  end

  def method_missing(name, *args, &block)
    key?(name) ? self[name] : super
  end

  def respond_to_missing?(name, include_private=false)
    key?(name) || super
  end

  def every_branch
    branches.map { |k, v| DotHash.from_branch({ k => v }) }
  end

  def every_stream
    branches.map { |k, v|
      [*k.to_s.split(/(?<!\\)\./).map { |part| part.gsub(/\\\./, ".") }, v]
    }
  end

  def branches(hash=:nothing_passed)
    hash = self if hash == :nothing_passed
    if hash.is_a?(::Hash)
      return hash if hash.none? { |_k, v| v.is_a?(::Hash) || v.is_a?(::Array) }
    elsif hash.is_a?(::Array)
      hash = hash.each_with_index.with_object(DotHash.new) { |(bval, idx), obj|
        obj[idx.to_s] = bval
      }
    else
      return hash
    end

    hash.each_with_object(DotHash.new) { |(k, v), obj|
      format_key = k.to_s.gsub(/(?<!\\)\./, "\\.") # Escape dots in keys

      bdata = branches(v)
      case bdata
      when ::Hash
        obj[format_key.to_s] = "" if bdata.blank?
        bdata.each do |bkey, bval|
          obj["#{format_key}.#{bkey}"] = bval
        end
      else
        obj[format_key.to_s] = bdata
      end
    }
  end
end

# class DotHash < Hash
#   # def self.from(hash)
#   #   ::JSON.parse(hash.to_json, object_class: DotHash, symbolize_names: true)
#   # end

#   def self.every_stream(hash)
#     from(hash).every_stream
#   end

#   #  IN={"event.dot\\.data.custom.nested_key"=>"fuzzy_val thing"}
#   # OUT={event: {"dot.data": {custom: {nested_key: "fuzzy_val thing"}}}}
#   def self.from_branch(hash)
#     hash.each_with_object({}) do |(key, value), result|
#       parts = key.to_s.split(/(?<!\\)\./).map { |part| part.gsub(/\\\./, ".") }
#       last_key = parts.pop
#       nested = parts.inject(result) { |h, k| h[k] ||= {} }
#       nested[last_key] = value
#     end
#   end

#   def method_missing(method, *args, &block)
#     if self.key?(method.to_s.to_sym)
#       self[method.to_s.to_sym]
#     else
#       super
#     end
#   end

#   def every_branch
#     branches.map { |k,v| DotHash.from_branch({ k => v }) }
#   end

#   def every_stream
#     branches.map { |k,v|
#       [*k.to_s.split(/(?<!\\)\./).map { |part| part.gsub(/\\\./, ".") }, v]
#     }
#   end

#   def branches(hash=:nothing_passed)
#     hash = self if hash == :nothing_passed
#     return hash unless hash.is_a?(::Hash) || hash.is_a?(::Array)
#     return hash if hash.is_a?(::Hash) && hash.none? { |k, v| v.is_a?(::Hash) }

#     # Hash with hashes
#     if hash.is_a?(::Array)
#       hash = hash.each_with_index.with_object({}) do |(bval, idx), obj|
#         obj["#{idx}"] = bval
#       end
#     end
#     hash.each_with_object({}) do |(k, v), obj|
#       format_key = k.to_s.gsub(/(?<!\\)\./, "\\.") # string.split(/(?<!\\)\./)

#       bdata = branches(v)
#       case bdata
#       when ::Hash
#         obj["#{format_key}"] = "" if bdata.blank?
#         bdata.each do |bkey, bval|
#           obj["#{format_key}.#{bkey}"] = bval
#         end
#       else
#         obj["#{format_key}"] = bdata
#       end
#     end
#   end
# end
