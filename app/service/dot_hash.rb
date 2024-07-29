class DotHash < Hash
  def self.from(hash)
    ::JSON.parse(hash.to_json, object_class: DotHash, symbolize_names: true)
  end

  def self.every_stream(hash)
    from(hash).every_stream
  end

  #  IN={"event.dot\\.data.custom.nested_key"=>"fuzzy_val thing"}
  # OUT={event: {"dot.data": {custom: {nested_key: "fuzzy_val thing"}}}}
  def self.from_branch(hash)
    hash.each_with_object({}) do |(key, value), result|
      parts = key.to_s.split(/(?<!\\)\./).map { |part| part.gsub(/\\\./, ".") }
      last_key = parts.pop
      nested = parts.inject(result) { |h, k| h[k] ||= {} }
      nested[last_key] = value
    end
  end

  def method_missing(method, *args, &block)
    if self.key?(method.to_s.to_sym)
      self[method.to_s.to_sym]
    else
      super
    end
  end

  def every_branch
    branches.map { |k,v| DotHash.from_branch({ k => v }) }
  end

  def every_stream
    branches.map { |k,v|
      [*k.to_s.split(/(?<!\\)\./).map { |part| part.gsub(/\\\./, ".") }, v]
    }
  end

  def branches(hash=:nothing_passed)
    hash = self if hash == :nothing_passed
    return hash unless hash.is_a?(::Hash) || hash.is_a?(::Array)
    return hash if hash.is_a?(::Hash) && hash.none? { |k, v| v.is_a?(::Hash) }

    # Hash with hashes
    if hash.is_a?(::Array)
      hash = hash.each_with_index.with_object({}) do |(bval, idx), obj|
        obj["#{idx}"] = bval
      end
    end
    hash.each_with_object({}) do |(k, v), obj|
      format_key = k.to_s.gsub(/(?<!\\)\./, "\\.") # string.split(/(?<!\\)\./)

      bdata = branches(v)
      case bdata
      when ::Hash
        bdata.each do |bkey, bval|
          obj["#{format_key}.#{bkey}"] = bval
        end
      else
        obj["#{format_key}"] = bdata
      end
    end
  end
end
