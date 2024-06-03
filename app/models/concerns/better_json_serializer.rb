class BetterJsonSerializer
  def self.dump(obj)
    obj.is_a?(String) ? obj : obj.try(:to_json) || JSON.dump(obj)
  end

  def self.load(str)
    start_str = str.dup
    safe_str = str.then { |s| next s if s.nil? || s.is_a?(String); s.to_json }
    json = safe_str.present? ? JSON.parse(safe_str, object_class: BetterJson) : str

    return json if json.is_a?(Hash) || json.is_a?(Array) || json.is_a?(BetterJson)
    start_str == json ? json : BetterJsonSerializer.load(json)
  rescue JSON::ParserError
    str
  end
end
