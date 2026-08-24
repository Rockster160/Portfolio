# Requests that are malformed at the protocol level never reach a controller —
# they blow up inside Rails' own request parsing, so they surface as exceptions
# instead of responses. Neither case here is a person: an Accept header that
# isn't a MIME type, and `PRI * HTTP/2.0`, the cleartext HTTP/2 connection
# preface, whose verb is not an HTTP method Rails knows.
class CatchMalformedRequestMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    return refuse("Not a valid HTTP method") unless known_method?(env)

    @app.call(env)
  rescue ActionDispatch::Http::MimeNegotiation::InvalidType
    refuse("Not a valid MIME type")
  end

  private

  def known_method?(env)
    ActionDispatch::Request::HTTP_METHOD_LOOKUP.key?(env["REQUEST_METHOD"])
  end

  def refuse(message)
    [405, { "Content-Type" => "text/plain" }, [message]]
  end
end
