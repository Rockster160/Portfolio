class CatchMimeNegotiation
  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  rescue ActionDispatch::Http::MimeNegotiation::InvalidType
    [405, { "Content-Type" => "text/plain" }, ["Not a valid MIME type"]]
  end
end
