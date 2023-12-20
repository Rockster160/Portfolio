class Api
  # BASE_URL="https://www.googleapis.com/calendar/v3"
  attr_accessor :res

  def self.get(uri, params={}, headers={})
    url = [uri, params.presence&.to_query].compact.join("?")
    pst "  \e[33mGET #{url}\e[0m"
    output(:Headers, headers)
    res = RestClient::Request.execute(method: :get, url: url, headers: headers)
    output("Response Headers", res.headers)
    JSON.parse(res.body, symbolize_names: true).tap { |json| output(:Response, json) }
  rescue RestClient::ExceptionWithResponse => res_exc
    pst "\e[31m  > #{res_exc} [#{res_exc.http_body}](#{res_exc.message})\e[0m"
    res_exc
  rescue StandardError => e
    pst "\e[31m  [ERROR]> #{e.message}\e[0m"
  ensure
    res&.body
  end

  def self.post(uri, params={}, headers={})
    # url = [uri, params.presence&.to_query].compact.join("?")
    url = uri # Include params?
    pst "  \e[33mPOST #{url}\e[0m"
    output(:Params, params)
    output(:Headers, headers)
    params = params.to_json if params.is_a?(Hash) && headers[:content_type] == "application/json"
    res = RestClient.post(url, params, headers)
    output("Response Headers", res.headers)
    JSON.parse(res.body, symbolize_names: true).tap { |json| output(:Response, json) }
  rescue RestClient::ExceptionWithResponse => res_exc
    pst "\e[31m  > #{res_exc} [#{res_exc.http_body}](#{res_exc.message})\e[0m"
    res_exc
  rescue StandardError => e
    pst "\e[31m  [ERROR]> #{e.message}\e[0m"
  ensure
    res&.body
  end

  def self.output(name, json)
    return if json.blank?

    padded = "  #{name}  "
    pst "  \e[90m#{padded.center(60, "=")}\e[0m"
    pst "  #{json.better.pretty.split("\n").join("\n  ")}"
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
