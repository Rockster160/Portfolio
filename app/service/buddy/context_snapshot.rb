module Buddy
  # Snapshots Buddy::Context.build to a JSON file on disk so Buddy can
  # Read it on-demand instead of receiving 5-8 KB of context in every
  # system prompt. Rails writes; Buddy reads via its Read tool.
  #
  # Path: ~/.byte/buddy-context/<user_id>.json (same host convention as
  # ~/.byte/buddy-memory.jsonl). Refreshed on every Buddy dispatch so
  # the file is guaranteed fresh at read time.
  module ContextSnapshot
    module_function

    DIR = File.expand_path("~/.byte/buddy-context").freeze

    def path_for(user)
      File.join(DIR, "#{user.id}.json")
    end

    def write_for(user, context = nil)
      context ||= Buddy::Context.build(user)
      FileUtils.mkdir_p(DIR)
      payload = {
        written_at: Time.current.iso8601,
        user_id:    user.id,
        context:    context,
      }
      tmp = "#{path_for(user)}.tmp.#{Process.pid}"
      File.write(tmp, JSON.pretty_generate(payload))
      File.rename(tmp, path_for(user))
      path_for(user)
    rescue => e
      Rails.logger.warn("[Buddy::ContextSnapshot] write failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
