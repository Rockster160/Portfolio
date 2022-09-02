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
      basic_auth_raw = request.headers["HTTP_AUTHORIZATION"].to_s[6..-1] # Strip "Basic " from hash
      basic_auth_raw = basic_auth_raw.presence || params[:basic_auth]
      return unless basic_auth_raw.present?

      basic_auth_string = Base64.decode64(basic_auth_raw)
      User.auth_from_basic(basic_auth_string)
    end

    def find_avatar
      Avatar.find_by(uuid: cookies.signed[:avatar_uuid])
    end
  end
end
