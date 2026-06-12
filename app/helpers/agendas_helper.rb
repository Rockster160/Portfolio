module AgendasHelper
  def location_is_url?(text)
    text.to_s.strip.match?(%r{\Ahttps?://}i)
  end
end
