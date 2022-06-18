class ProxyRequest

  def self.execute(data)
    new.execute(data)
  end

  def execute(data)
    data = data.with_indifferent_access
    @method = data[:method]&.downcase&.to_sym || :get
    @url = data[:url]
    @params = data[:params] || {}
    @headers = data[:headers] || {}

    @response = @method.in?([:get, :delete]) ? request_with_header_params : request_with_payload

    json
  end

  def request_with_header_params
    RestClient::Request.execute(
      method: @method,
      url: @url,
      headers: @headers.merge(params: @params)
    )
  end

  def request_with_payload
    RestClient::Request.execute(
      method: @method,
      url: @url,
      payload: @params.to_json,
      headers: @headers
    )
  end

  def json
    JSON.parse(@response.body)
  rescue JSON::ParserError
    @response
  end
end
