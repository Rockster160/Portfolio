module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_avatar

    def connect
      self.current_user = find_verified_user
      self.current_avatar = find_avatar
      logger.add_tags "ActionCable", current_user.try(:username) || "Guest"
    end

    protected

    def find_verified_user # this checks whether a user is authenticated
      current_user_id = cookies.signed[:current_user_id].presence || cookies.permanent[:current_user_id].presence || cookies.signed[:user_id].presence
      User.find_by(id: current_user_id)
    end

    def find_avatar
      Avatar.find_by(uuid: cookies.signed[:avatar_uuid])
    end
  end
end
