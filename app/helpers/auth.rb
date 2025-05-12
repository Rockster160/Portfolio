class Auth
  include AuthHelper

  def initialize(session, request)
    @_auth_session = session
    @_auth_request = request
  end

  def session
    (defined?(super) ? super() : nil) || @_auth_session
  end

  def request
    (defined?(super) ? super() : nil) || @_auth_request
  end

  def cookies
    defined?(super) ? super() : nil
  end
end
