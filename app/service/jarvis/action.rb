class Jarvis::Action
  attr_accessor :user, :msg, :current_reserved_words, :rx

  def self.attempt(user, msg, current_reserved_words=nil)
    current_reserved_words&.select! { |word| reserved_words.exclude?(word) }
    words = current_reserved_words.nil? ? Jarvis.reserved_words : current_reserved_words
    new(user, msg, words).attempt
  end

  def self.reserved_words
    []
  end

  def initialize(user, msg, words)
    @user = user
    @msg = msg
    @current_reserved_words = words
    @rx = Jarvis::Regex
  end
end
