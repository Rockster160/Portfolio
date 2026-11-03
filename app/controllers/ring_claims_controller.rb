# Which screen plays a status ring's sound.
#
# Every screen showing a feed's rings works out for itself that one has run out,
# so left alone each of them plays it - and a page that reloads plays it again.
# The first screen to claim a sounding wins it and plays; every other claim for
# the same one is told no.
#
# A sounding is the feed's owner, the ring's key, the moment it ran out, and
# which five-minute repeat it is: a ring re-armed with a new end time is a new
# sounding, and so is each repeat while it stays overdue.
#
# No CSRF check: wall screens stay open for weeks with whatever token they
# loaded with, and the only thing this writes is a key that expires on its own.
class RingClaimsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  CLAIM_TTL = 15.minutes

  def create
    owner = params[:owner_id].to_i
    key   = params[:key].to_s.first(64)
    at    = params[:at].to_i
    slot  = params[:slot].to_i
    return head(:unprocessable_entity) if key.blank? || at <= 0 || slot.negative?

    won = Rails.cache.write("ring-claim:#{owner}:#{key}:#{at}:#{slot}", true, unless_exist: true, expires_in: CLAIM_TTL)
    render json: { play: won.present? }
  end
end
