Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "https://ardesian.com", "https://rocconicholls.me", "https://rdjn.me"
    resource "*", headers: :any, methods: :any
  end
end
