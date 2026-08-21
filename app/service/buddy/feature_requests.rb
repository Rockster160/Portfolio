module Buddy
  # Getting a written-down gap in front of the one person who can close it.
  #
  # A companion filing one is the easy half. The hard half is that the person
  # who hit the wall is usually not the person who can do anything about it —
  # Eve asks Suki for a work rhythm, and the list it lands on is only useful if
  # it reaches the owner. So it's delivered, once, as an ordinary message from
  # their own companion rather than parked somewhere to be found later.
  module FeatureRequests
    module_function

    # How many to hand the model when it asks. Enough to answer "what have
    # people been asking for", short enough that it isn't a report.
    CONTEXT_LIMIT = 12

    def notify_owner!(request)
      return false unless request.notify_owner?

      owner = FeatureRequest.owner
      convo = Buddy::CompanionRelay.conversation_for(owner)
      return false if convo.nil?

      Buddy::CompanionDelivery.deliver_plain(
        user:         owner,
        conversation: convo,
        text:         "📮 #{request.user.first_name} asked for something I couldn't do: " \
                      "**#{request.title}**\n\n#{request.body}",
        metadata:     {
          "kind"               => "buddy",
          "source"             => "feature_request",
          "feature_request_id" => request.id,
        },
        push_title:   "#{request.user.first_name}: #{request.title}",
      )
      true
    rescue StandardError => e
      # The row is written either way. A delivery that fails must not take the
      # request down with it — the whole point is that the gap stops being lost.
      Buddy::Errors.report(section: "feature_requests.notify", exception: e, user: request.user)
      false
    end

    # What's on the list, for `get_context`. Everyone sees their OWN; the owner
    # sees the house's, because they're the one who'd act on any of it.
    def context_for(user)
      scope = FeatureRequest.live.recent
      scope = (user&.id == FeatureRequest.owner&.id ? scope : scope.where(user_id: user&.id))

      scope.limit(CONTEXT_LIMIT).includes(:user).map { |row|
        {
          id:     row.id,
          title:  row.title,
          who:    row.user&.first_name,
          status: row.status,
          asked:  row.created_at.to_date.to_s,
        }
      }
    rescue StandardError => e
      Buddy::Errors.report(section: "feature_requests.context", exception: e, user: user)
      []
    end
  end
end
