module Jilable
  extend ActiveSupport::Concern

  attr_accessor :execution_attrs

  def with_jil_attrs(attrs={})
    @execution_attrs = attrs
    self
  end

  def [](key)
    return @execution_attrs[key] if @execution_attrs.is_a?(Hash) && @execution_attrs.key?(key)

    super
  end

  def dig(*keys)
    key, *rest = keys
    self[key]&.then { |v| rest.any? ? v&.dig(*rest) : v }
  end

  def merge(hash)
    @execution_attrs ||= {}
    @execution_attrs.merge!(hash)
    self
  end
end
