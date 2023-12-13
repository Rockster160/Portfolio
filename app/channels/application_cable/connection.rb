module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_avatar

    def connect
      self.current_user = find_verified_user
      self.current_avatar = find_avatar # Only if in LittleWorld
      logger.add_tags "ActionCable", current_user.try(:username) || "Guest"
    end

    protected

    def find_verified_user # this checks whether a user is authenticated
      current_user_id = cookies.signed[:current_user_id].presence || cookies.permanent[:current_user_id].presence || cookies.signed[:user_id].presence

      return User.find(current_user_id) if current_user_id.present?

      user = user_from_headers
      return user if user

      reject_unauthorized_connection
    end

    def user_from_headers
      raw_auth = request.headers["HTTP_AUTHORIZATION"]
      return unless raw_auth.present?

      # Had issues where some clients were mixing up bearer vs basic
      # Just made this work for whatever prefix
      type, auth_string = raw_auth.split(" ", 2)
      basic_auth_string = Base64.decode64(auth_string)

      if basic_auth_string.include?(":")
        puts "\e[33m[LOGIT] | [WS]String found. Authing: [#{basic_auth_string}]\e[0m"
        User.auth_from_basic(basic_auth_string)
      else
        puts "\e[33m[LOGIT] | [WS]API Key found. Authing: [#{auth_string}]\e[0m"
        ApiKey.find_by(key: auth_string)&.user
      end
    end

    def find_avatar
      Avatar.find_by(uuid: cookies.signed[:avatar_uuid])
    end
  end
end
