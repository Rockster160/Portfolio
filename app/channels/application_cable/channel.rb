module ApplicationCable
  class Channel < ActionCable::Channel::Base
    def subscribed
      super
      ::PrettyLogger.info("\e[35m[WS:SUB] #{self.class.name} | user=#{current_user&.username || "guest"} | params=#{params.except(:channel).to_json}\e[0m")
    end

    def pretty_log_data(data)
      identifier = (
        if current_user
          "\e[36m[#{current_user.try(:username).presence || "User #{current_user.try(:id)}"}]"
        else
          "\e[31m[?]"
        end
      )
      ::PrettyLogger.info("\e[35m[WS]#{identifier}\n\e[0m#{PrettyLogger.pretty_message(data.deep_symbolize_keys)}")
    end
  end
end
