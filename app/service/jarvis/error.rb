class Jarvis::Error < StandardError
  def self.not_allowed
    new("Sorry, you can't do that.")
  end
end
