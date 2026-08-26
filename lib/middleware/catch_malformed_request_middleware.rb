# Requests that are malformed at the protocol level never reach a controller —
# they blow up inside Rails' own request parsing, so they surface as exceptions
# instead of responses. No case here is a person: an Accept header that isn't a
# MIME type; `PRI * HTTP/2.0`, the cleartext HTTP/2 connection preface, whose
# verb is not an HTTP method Rails knows; and a body that stops short of the
# Content-Length it declared, which raises EOFError the moment anything reads
# it. That read happens in Rack::Attack's logins/email throttle, below this
# middleware in the stack and well before routing, so there is no request left
# to serve — only a status to pick.
class CatchMalformedRequestMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    return refuse("Not a valid HTTP method") unless known_method?(env)

    @app.call(env)
  rescue ActionDispatch::Http::MimeNegotiation::InvalidType
    refuse("Not a valid MIME type")
  rescue EOFError
    refuse("Incomplete request body", status: 400)
  end

  private

  def known_method?(env)
    ActionDispatch::Request::HTTP_METHOD_LOOKUP.key?(env["REQUEST_METHOD"])
  end

  def refuse(message, status: 405)
    [status, { "Content-Type" => "text/plain" }, [message]]
  end
end
