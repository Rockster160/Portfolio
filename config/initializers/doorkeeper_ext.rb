Rails.application.config.to_prepare do
  Doorkeeper::AuthorizationsController.include AuthHelper
end
