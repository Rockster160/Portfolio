module TrackerLogger
  module_function

  def log_request(request, user=nil)
    return unless trackable?(request)

    filtered_params = filter_hash(request.env["action_dispatch.request.parameters"])

    LogTracker.create(
      user_agent:  request.user_agent,
      ip_address:  request.try(:remote_ip),
      http_method: request.env["REQUEST_METHOD"],
      url:         request.env["REQUEST_PATH"],
      params:      filtered_params,
      headers:     request&.headers&.env&.reject { |key| key.to_s.include?(".") },
      body:        request.try(:raw_post).inspect.presence || request.try(:body).inspect.presence,
      user_id:     user.try(:id),
    )
  end

  def trackable?(request)
    return false unless Rails.env.production?
    return false if request.env["REQUEST_PATH"]&.include?("log_tracker")
    # TODO: Should check Dashboard UserAgent -- OR! Include some kind of param/token/header
    #   that disables the log tracker
    return false if request.env["REQUEST_PATH"] == "/webhooks/local_ping"
    return false if request.env["REQUEST_PATH"] == "/webhooks/report"
    return false if request.env["REQUEST_PATH"] == "/printer_control"

    true
  end

  def filter_hash(hash)
    new_hash = hash.deep_dup
    dangerous_keys = new_hash.keys.grep(/password/)
    dangerous_keys.each { |k|
      new_hash[k].is_a?(String) ? new_hash[k] = "[[FILTERED PASSWORD]]" : nil
    }
    new_hash.each do |hash_key, hash_val|
      new_hash[hash_key] = filter_hash(new_hash[hash_key]) if hash_val.is_a?(Hash)
    end
    new_hash
  end
end
