# frozen_string_literal: true

class SymbolizedJsonFormatter < ActiveRecord::Type::Json
  def self.cast(value)
    deep_cast(new.cast(value))
  end

  def self.deserialize(value)
    deep_cast(new.deserialize(value))
  end

  def self.deep_cast(value)
    case value
    when Hash then value.deep_symbolize_keys.transform_values { |v| deep_cast(v) }
    when Array then value.map { |v| deep_cast(v) }
    else value
    end
  end

  def self.method_missing(method, *, &)
    new.public_send(method, *, &)
  end
end
