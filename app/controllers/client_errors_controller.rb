# Where the browser reports its own failures: an uncaught error or a rejected
# promise on any page. They are recorded and announced like every other
# failure, grouped by the page they happened on.
#
# No CSRF check: a page held open for days reports with whatever token it
# loaded with, and a failure is worth hearing about most from exactly the page
# that has gone stale.
class ClientErrorsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  # Reports one person's screens can send in a stretch. A loop throwing on every
  # frame is one failure, and its first few say everything the rest would.
  LIMIT = 30
  LIMIT_WINDOW = 10.minutes

  def create
    return head(:too_many_requests) if over_limit?

    ClientErrors.report(
      user:    current_user,
      message: params[:message].to_s,
      name:    params[:name].to_s,
      stack:   params[:stack].to_s,
      page:    params[:page].to_s,
      build:   params[:build].to_s,
      extra:   {
        kind:       params[:kind].to_s.first(20).presence,
        source:     params[:source].to_s.first(300).presence,
        url:        params[:url].to_s.first(500).presence,
        user_agent: request.user_agent.to_s.first(300).presence,
      }.compact,
    )
    head(:no_content)
  end

  private

  def over_limit?
    key = "client-errors:#{current_user.id}:#{Time.current.to_i / LIMIT_WINDOW.to_i}"
    count = Rails.cache.increment(key, 1, expires_in: LIMIT_WINDOW)
    count.to_i > LIMIT
  end
end
