::OpenAI.configure do |config|
  config.access_token = ENV.fetch("PORTFOLIO_OPENAI_KEY")
end

# client = OpenAI::Client.new
#
# prompt = "In one or two words but less than 20 characters, summarize the following:"
# item = "Coolife Luggage 3 Piece Set Suitcase Spinner Hardshell Lightweight TSA Lock (blue)"
#
# response = client.chat(
#   parameters: {
#     model: "gpt-3.5-turbo", # Required.
#     messages: [{ role: "user", content: "#{prompt} #{item}" }], # Required.
#     })
# puts response.dig("choices", 0, "message", "content")
