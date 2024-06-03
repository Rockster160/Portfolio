class SafeJsonSerializer
  def self.dump(obj)
    obj.is_a?(String) ? obj : obj.try(:to_json) || JSON.dump(obj)
  end

  def self.load(str)
    start_str = str.dup
    safe_str = (start_str.is_a?(::String) ? start_str : start_str.try(:to_json)) || start_str
    json = safe_str.present? ? JSON.parse(safe_str, symbolize_names: true) : str

    return json if json.is_a?(::Hash) || json.is_a?(::Array)
    start_str == json ? json : ::SafeJsonSerializer.load(json)
  rescue JSON::ParserError
    str
  end
end
