class Jil::Methods::Oauth < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
    # case value
    # else @jil.cast(value, :Hash)
    # end
  end

  # [Oauth]
  #   #new("Service Name" TAB String BR "Authorization Endpoint" TAB String:"URL" BR "Exchange Endpoint" TAB String:"URL" BR "Base URI" TAB String:"URL" BR "Scopes" TAB Any:"Array|String" BR "Client ID" TAB String BR "Client Secret" TAB Password)
  #   .auth_url::String
  #   .get("URL" String BR "Params" Hash BR "Headers" Hash)::Hash
  #   .post("URL" String BR "Params" Hash BR "Headers" Hash)::Hash
  #   .patch("URL" String BR "Params" Hash BR "Headers" Hash)::Hash
  #   .put("URL" String BR "Params" Hash BR "Headers" Hash)::Hash
  #   .delete("URL" String BR "Params" Hash BR "Headers" Hash)::Hash
  #   .request("Method" String BR "URL" String BR "Params" Hash BR "Headers" Hash)::Hash

  # Eventually this should store all of these settings and then have a different quick lookup by service name
  def connection(service, auth_url, exchange_url, base_uri, scopes, client_id, client_secret)
    connect(
      service:       service,
      oauth_url:     auth_url,
      exchange_url:  exchange_url,
      api_url:       base_uri,
      scopes:        scopes,
      client_id:     client_id,
      client_secret: client_secret,
    )
  end

  def auth_url(oauth)
    connect(oauth).auth_url
  end

  def get(oauth, path)
    req(oauth, path, method: :get)
  end

  def getFull(oauth, path, params, headers)
    req(oauth, path, params, headers, method: :get)
  end

  def post(oauth, path, params, headers)
    req(oauth, path, params, headers, method: :post)
  end

  def patch(oauth, path, params, headers)
    req(oauth, path, params, headers, method: :patch)
  end

  def put(oauth, path, params, headers)
    req(oauth, path, params, headers, method: :put)
  end

  def delete(oauth, path, params, headers)
    req(oauth, path, params, headers, method: :delete)
  end

  def request(oauth, method, path, params, headers)
    req(oauth, path, params, headers, method: method)
  end

  private

  def connect(data)
    constants = data.slice(:service, :oauth_url, :exchange_url, :api_url, :scopes).compact_blank
    ::Oauth::Base.new(@jil.user, constants).tap { |o|
      o.client_id = data[:client_id]
      o.client_secret = data[:client_secret]
    }
  end

  def req(oauth, path, params={}, headers={}, method: :get)
    connect(oauth).request(path, method, params, headers, {})
  rescue RestClient::Exception => e
    {
      message:  e.message,
      status:   e.try(:http_code) || 500,
      response: safe_json(e.try(:response)&.body),
    }
  end

  def safe_json(json)
    JSON.parse(json, symbolize_names: true)
  rescue JSON::ParserError
    json
  end
end
