module Buddy
  # Reading a deploy: whether a trigger is about one, whether it succeeded, and
  # which commit it was.
  #
  # Split out of Buddy::WatchMatcher, which owns which watch fires and how its
  # state advances. Deploys are the one trigger that needs interpreting rather
  # than matching, because nothing about them arrives in one piece:
  #
  #   { deploy: "success" }                    the app's own `startup` trigger
  #   { id: "deploy", deploy: "failed", sha: } the workflow's failure hook
  #   { channel: "deploy:success" }            the cable re-broadcast
  #
  # One deploy emits several of these, seconds apart, and they don't agree
  # about where the outcome lives or whether the commit is named at all.
  module DeploySignal
    module_function

    OUTCOMES = {
      "success"   => :success,
      "succeeded" => :success,
      "finished"  => :success,
      "failed"    => :failed,
      "failure"   => :failed,
      "error"     => :failed,
    }.freeze

    # How far back a Deploy row can be and still be THIS deploy. A deploy runs
    # two to three minutes; a restart half an hour after the last one is not
    # that deploy, and stamping its commit on would be worse than saying
    # nothing. In practice the correlation is tighter still - `startup` only
    # fires when the running sha CHANGES, which only a deploy does.
    LOOKBACK = 30.minutes

    # :success / :failed once a deploy is over, nil while it's still running.
    # Emitters disagree about where the outcome lives, so read all three:
    #   .github/workflows/deploy.yml posts `deploy=finished|failed|start`
    #   the cable re-broadcast names it in the channel (`deploy:success`)
    #   others put it in `status`
    def outcome(payload)
      data = indifferent(payload)
      [
        data[:status],
        data[:deploy],
        data[:channel].to_s.split(":", 2).last,
      ].filter_map { |raw| OUTCOMES[raw.to_s.strip.downcase] }.first
    end

    # Is this monitor broadcast about a deploy at all? A `deploy` key is enough
    # on its own - that's the startup trigger's whole payload.
    def about_deploy?(payload)
      data = indifferent(payload)
      data.key?(:deploy) ||
        data[:id].to_s.strip.downcase == "deploy" ||
        data[:channel].to_s.strip.downcase.start_with?("deploy")
    end

    # Fill in WHICH commit, when the signal itself doesn't say.
    #
    # The signal that wins the race is `startup`, and its whole payload is
    # `{deploy: "success"}` - so for months every deploy notification said one
    # had happened and never which one. The workflow's hook carries the sha and
    # the commit message, but it arrives second and collapses as a duplicate.
    #
    # Waiting for it would add latency to every deploy and still lose when it
    # 502s; announcing again when it lands would mean two pings each time.
    # Neither is needed: the workflow posts these at `deploy=start`, which is
    # what creates the Deploy ActionEvent, minutes before any of this runs.
    #
    # Anything the signal DID carry wins - a failure hook knows its own sha,
    # and the row is only the fallback.
    def with_commit(user, payload)
      data = indifferent(payload)
      return payload if data[:sha].present?

      details = commit_details(user)
      return payload if details.empty?

      data.to_h.merge(details)
    rescue StandardError => e
      # A notification with no commit on it is the status quo; one that never
      # arrives because a lookup blew up is a regression.
      Rails.logger.warn("[Buddy::DeploySignal] commit lookup failed: #{e.class}: #{e.message}")
      payload
    end

    def commit_details(user)
      event = ActionEvent.where(user_id: user.id, name: "Deploy")
        .where(created_at: LOOKBACK.ago..)
        .order(created_at: :desc)
        .first
      event&.data.to_h.slice("sha", "message", "author").compact_blank
    end

    def indifferent(payload)
      payload.is_a?(Hash) ? payload.with_indifferent_access : {}.with_indifferent_access
    end
  end
end
