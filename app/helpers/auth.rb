class Auth
  include AuthHelper

  attr_accessor :session, :request, :cookies

  def initialize(session, request)
    @session = session
    @request = request
  end
end
