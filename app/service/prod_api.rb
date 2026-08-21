module ProdApi
  module_function

  PROD_URL = "https://ardesian.com/api/v1".freeze

  def get(path, params={}, headers={}, opts={})
    Api.get(url(path), params, headers.reverse_merge(authorization), opts)
  end

  def post(path, params={}, headers={}, opts={})
    Api.post(url(path), params, headers.reverse_merge(authorization), opts)
  end

  def put(path, params={}, headers={}, opts={})
    Api.put(url(path), params, headers.reverse_merge(authorization), opts)
  end

  def patch(path, params={}, headers={}, opts={})
    Api.patch(url(path), params, headers.reverse_merge(authorization), opts)
  end

  def delete(path, params={}, headers={}, opts={})
    Api.delete(url(path), params, headers.reverse_merge(authorization), opts)
  end

  # A path segment is an identifier, so callers write it as one — `:buddy_usages`
  # rather than a string. The Array branch has always taken symbols (`join`
  # stringifies), and this one raised on them.
  def url(path)
    if path.is_a?(Array)
      "#{PROD_URL}/#{path.join("/")}"
    else
      "#{PROD_URL}/#{path.to_s.sub(/^\/+/, "")}"
    end
  end

  def authorization
    { Authorization: "Bearer #{ENV.fetch("PORTFOLIO_LOCAL_APIKEY")}" }
  end
end
