module Slack
  # One-tap controls posted into Slack.
  #
  # Slack's own interactive buttons need an app with Interactivity configured, a
  # public Request URL, and every POST verified against the signing secret. This
  # is the other way, and it is the one already in use: a LINK in the message
  # that opens a page in the app, locked to `User.me` the same way
  # TeslaSwitchController is. One tap from a phone, nothing to configure on
  # Slack's side, and no new secret to hold.
  #
  # Adding one is a register call and nothing else:
  #
  #   Slack::Actions.register(
  #     :buddy_retry,
  #     label: "🔄 Try Buddy again",
  #     run:   ->(_params) { Buddy::Outage.retry! },
  #   )
  #
  # then put `Slack::Actions.link(:buddy_retry)` in the message. The handler
  # returns a string, which is what the person sees when the page opens — so it
  # should say what actually happened, not what was attempted.
  module Actions
    module_function

    Handler = Struct.new(:name, :label, :run, keyword_init: true)

    def registry
      @registry ||= {}
    end

    def register(name, label:, run:)
      registry[name.to_sym] = Handler.new(name: name.to_sym, label: label, run: run)
    end

    def find(name)
      registry[name.to_s.to_sym]
    end

    # Runs the handler and returns what it said. An unknown name is not an error
    # worth a stack trace — a link outlives the feature it was posted for, and
    # somebody tapping a month-old message should be told that rather than shown
    # a 500.
    def call(name, params={})
      handler = find(name)
      return [:unknown, "That control isn't a thing any more."] if handler.nil?

      [:ok, handler.run.call(params).to_s]
    rescue StandardError => e
      Rails.logger.error("[Slack::Actions] #{name} failed: #{e.class}: #{e.message}")
      [:error, "#{e.class}: #{e.message}"]
    end

    # Slack's `<url|label>` link syntax, ready to drop into a message body.
    def link(name, label: nil, **params)
      handler = find(name)
      text  = label || handler&.label || name.to_s
      query = params.any? ? "?#{params.to_query}" : ""

      "<#{base_url}/slack/action/#{name}#{query}|#{text}>"
    end

    def base_url
      Rails.env.production? ? "https://ardesian.com" : "http://localhost:3141"
    end
  end
end
