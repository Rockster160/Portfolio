class API
  # BASE_URL="https://www.googleapis.com/calendar/v3"
  attr_accessor :res

  def self.get(uri, params={}, headers={})
    url = "#{uri}?#{params.to_query}"
    puts "  \e[33mGET #{url}\e[0m"
    @res = RestClient.get(url)
    JSON.parse(@res.body, symbolize_names: true)
  rescue StandardError => e
    puts "\e[31m  > #{e}\e[0m"
    @res&.body
  end

  def self.post(uri, params={}, headers={})
    url = "#{uri}?#{params.to_query}"
    puts "  \e[33mPOST #{url}\e[0m"
    puts "  #{params.better.pretty.split("\n").join("\n  ")}"
    @res = RestClient.post(uri, params)
    JSON.parse(@res.body, symbolize_names: true)
  rescue StandardError => e
    puts "\e[31m  > #{e}\e[0m"
    @res&.body
  end

  def initialize(base_url, always_params = {}, always_headers = {})
    @base_url = base_url.gsub(/\/*$/, "")
    @always_params = always_params
    @always_headers = always_headers
  end

  def get(path, params = {}, _headers = {})
    path = path.gsub(/^\/*/, "")
    param_string = params.merge(@always_params).to_query
    # Headers?

    url = "#{@base_url}/#{path}?#{param_string}"
    puts "  \e[33mGET #{url}\e[0m"
    @res = RestClient.get(url)
    JSON.parse(@res.body, symbolize_names: true)
  rescue StandardError => e
    puts "\e[31m  > #{e}\e[0m"
    @res&.body
  end
end
