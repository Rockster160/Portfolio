class SafeJsonSerializer
  def self.dump(obj)
    obj.is_a?(String) ? obj : JSON.dump(obj)
  end

  def self.load(str)
    safe_str = str.then { |s| next s if s.nil? || s.is_a?(String); s.to_json }
    safe_str.present? ? JSON.parse(safe_str, object_class: BetterJson, symbolize_names: true) : str
  rescue JSON::ParserError
    str
  end
end
