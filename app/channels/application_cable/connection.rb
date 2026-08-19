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
      user = user_from_headers
      return user if user
      return reject_unauthorized_connection if cookies.nil? # Cookies are undefined in broadcasts

      current_user_id = (
        cookies.signed[:current_user_id].presence ||
        cookies.permanent[:current_user_id].presence ||
        cookies.signed[:user_id].presence ||
        user_id_from_session
      )

      return User.find(current_user_id) if current_user_id.present?

      reject_unauthorized_connection
    end

    # Signed cookies default to host-scope, so they don't cross the
    # subdomain boundary when a page on whisper.ardesian.com connects
    # to wss://ardesian.com/cable. The session cookie IS domain-scoped
    # (session_store.rb sets `domain: :all`), so read the user id from
    # there as a cross-subdomain fallback.
    def user_id_from_session
      session_key = Rails.application.config.session_options[:key]
      session = cookies.encrypted[session_key]
      session.is_a?(::Hash) ? (session["current_user_id"] || session[:current_user_id]) : nil
    rescue StandardError
      nil
    end

    # ws://url/cable?Authorization="Bearer <raw_api_key>"
    # ws://url/cable headers: { Authorization: "Bearer <b64(username:password)>" }
    # Had issues where some clients were mixing up bearer vs basic, so the
    # prefix is ignored and both are tried.
    #
    # API KEY FIRST, and that order is the whole point. This used to decide by
    # base64-decoding the token and asking whether the result contained a colon
    # — but an API key is hex, and hex decodes to arbitrary bytes, so roughly
    # one key in eight decodes to something with a colon in it and was handed to
    # basic auth instead. Not a flake in the usual sense: whether a given key
    # can ever open a socket is fixed at the moment it's generated, and one that
    # can't never will. AuthHelper#user_from_auth_string was fixed for exactly
    # this and carries the same note; this copy was missed.
    def user_from_headers
      raw_auth = request.headers["HTTP_AUTHORIZATION"] || request.parameters["Authorization"]
      return if raw_auth.blank?

      type, auth_string = raw_auth.split(" ", 2)
      token = auth_string.presence || type

      ApiKey.authenticate(token)&.user || user_from_basic(token)
    rescue StandardError
      # NoMethodError might get thrown if the raw_auth is not b64
      nil
    end

    def user_from_basic(token)
      decoded = Base64.decode64(token.to_s)
      return nil unless decoded.include?(":")

      User.auth_from_basic(decoded)
    end

    def find_avatar
      Avatar.find_by(uuid: cookies.signed[:avatar_uuid])
    end
  end
end
