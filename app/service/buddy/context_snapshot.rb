module Buddy
  # Builds a snapshot of Buddy::Context.build in the shape written to
  # ~/.byte/buddy-context/<user_id>.json on the Mac. Rails does NOT
  # write the file itself - it can't, since Rails runs on a Linux
  # deploy host in prod while Buddy runs on Rocco's Mac. Instead, Rails
  # ships the payload inline in the /byte/incoming envelope and the Mac's
  # Handler writes it to Mac-local disk before invoking Buddy.
  #
  # The Mac path is a fixed convention ("~/.byte/buddy-context/<user_id>.json"
  # relative to the Mac's home). Rails constructs the string as-if from
  # that convention so Buddy is told the path it will actually find the
  # file at post-write.
  module ContextSnapshot
    module_function

    MAC_HOME    = "/Users/zoro".freeze
    MAC_DIR     = "#{MAC_HOME}/.byte/buddy-context".freeze

    def mac_path_for(user)
      File.join(MAC_DIR, "#{user.id}.json")
    end

    def build_for(user, conversation, context = nil)
      context ||= Buddy::Context.build(user, conversation)
      {
        written_at: Time.current.iso8601(6),
        user_id:    user.id,
        context:    context,
      }
    rescue => e
      Buddy::Errors.report(section: "context_snapshot.build", exception: e, user: user)
      nil
    end
  end
end
