class Auth
  include AuthHelper

  attr_accessor :session

  def initialize(session)
    @session = session
  end
end
