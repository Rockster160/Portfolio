class Jarvis::Action
  attr_accessor :user, :msg, :rx

  def self.attempt(user, msg)
    new(user, msg).attempt
  end

  def initialize(user, msg)
    @user = user
    @msg = msg
    @rx = Jarvis::Regex
  end
end
