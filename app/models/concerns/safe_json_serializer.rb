class SafeJsonSerializer
  def self.dump(obj)
    obj.is_a?(String) ? obj : JSON.dump(obj)
  end

  def self.load(str)
    str.present? ? JSON.parse(str).try(:deep_symbolize_keys) : str
  rescue JSON::ParserError
    str
  end
end
