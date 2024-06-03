class Api
  # BASE_URL="https://www.googleapis.com/calendar/v3"
  attr_accessor :res

  def self.get(uri, params={}, headers={}, opts={})
    url = [uri, params.presence&.to_query].compact.join("?")
    pst "  \e[33mGET #{url}\e[0m"
    output(:Headers, headers)
    res = RestClient::Request.execute(method: :get, url: url, headers: headers)
    output("Response Headers", res.headers)
    return res if opts[:return_full_response]
    JSON.parse(res.body, symbolize_names: true).tap { |json| output(:Response, json) }
  rescue JSON::ParserError
    res&.body
  rescue RestClient::ExceptionWithResponse => res_exc
    pst "\e[31m  > #{res_exc} [#{res_exc.message}](#{res_exc.http_body})\e[0m"
    raise res_exc
  rescue StandardError => e
    pst "\e[31m  [ERROR]> #{e.message}\e[0m"
    raise e
  ensure
    res&.body
  end

  def self.post(uri, params={}, headers={}, opts={})
    # url = [uri, params.presence&.to_query].compact.join("?")
    url = uri # Include params?
    pst "  \e[33mPOST #{url}\e[0m"
    output(:Params, params)
    output(:Headers, headers)
    params = params.to_json if params.is_a?(Hash) && headers[:content_type] == "application/json"
    res = RestClient.post(url, params, headers)
    output("Response Headers", res.headers)
    return res if opts[:return_full_response]
    JSON.parse(res.body, symbolize_names: true).tap { |json| output(:Response, json) }
  rescue JSON::ParserError
    res&.body
  rescue RestClient::ExceptionWithResponse => res_exc
    pst "\e[31m  > #{res_exc} [#{res_exc.message}](#{res_exc.http_body})\e[0m"
    raise res_exc
  rescue StandardError => e
    pst "\e[31m  [ERROR]> #{e.message}\e[0m"
    raise e
  ensure
    res&.body
  end

  def self.request(url:, **opts)
    return_full_response = opts.delete(:return_full_response)
    method = opts[:method] || :get
    pst "  \e[33m#{method.to_s.upcase} #{url}\e[0m"
    output(:Payload, opts[:payload]) if opts[:payload]
    output(:Headers, opts[:headers]) if opts[:headers]
    if opts[:payload].is_a?(::Hash) && opts[:headers][:content_type] == "application/json"
      opts[:payload] = opts[:payload].to_json
    end
    res = ::RestClient::Request.execute(
      method: method,
      url: url,
      # ssl_ca_file: opts[:ssl_ca_file],
      **opts
    )
    output("Response Headers", res.headers)
    return res if return_full_response
    JSON.parse(res.body, symbolize_names: true).tap { |json| output(:Response, json) }
  rescue JSON::ParserError
    res&.body
  rescue RestClient::ExceptionWithResponse => res_exc
    pst "\e[31m  > #{res_exc} [#{res_exc.message}](#{res_exc.http_body})\e[0m"
    raise res_exc
  rescue StandardError => e
    pst "\e[31m  [ERROR]> #{e.message}\e[0m"
    raise e
  ensure
    res&.body
  end

  def self.output(name, json)
    return if json.to_s.gsub(/\s/, "").length == 0 # .blank?

    padded = "  #{name}  "
    pst "  \e[90m#{padded.center(60, "=")}\e[0m"
    pst "  #{pretty_obj(json).split("\n").join("\n  ")}"
  end

  def self.pretty_obj(obj)
    return obj.to_s unless obj.is_a?(::Hash) || obj.is_a?(::Array)

    ::CodeRay.scan(obj, :ruby).terminal.gsub(
      /\e\[32m\e\[1;32m\"\e\[0m\e\[32m(\w+)\e\[1;32m\"\e\[0m\e\[32m\e\[0m=>/, ("\e[36m" + '\1: ' + "\e[0m")
    ).gsub(
      /\e\[36m:(\w+)\e\[0m=>/i, ("\e[36m" + '\1: ' + "\e[0m") # hashrocket(sym) to colon(sym)
    ).gsub(
      /\e\[0m=>/, "\e[0m: " # all hashrockets to colons
    ).gsub(
      "\e[1;36mnil\e[0m", "\e[1;90mnil\e[0m"
    )
  end

  def initialize(base_url, always_params = {}, always_headers = {})
    @base_url = base_url.gsub(/\/*$/, "")
    @always_params = always_params
    @always_headers = always_headers
  end

  def self.pst(str)
    return if Rails.env.production?

    puts str
  end

  def pst(str)
    self.class.pst(str)
  end
end
