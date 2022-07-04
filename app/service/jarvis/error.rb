class Jarvis::Error < StandardError
  def self.not_allowed
    [self, "Sorry, you can't do that."]
  end
end
