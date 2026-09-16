# The endpoint behind the strip in the corner of the hero: whatever is running
# elsewhere says here that it is running, how far along it is, and when it is
# done. See `docs/background_processes.md` for the caller's side of it.
#
# ONE surface for both sides. The scripts write through it with an API key, and
# the page hydrates and clears through the same four routes with a session -
# which means the "clear it by hand because it is stuck" button is the exact
# call a script makes when it finishes, and there is only one set of semantics
# to keep straight.
#
# Every route is an upsert or a no-op, and none of them can fail for having been
# called twice:
#
#   GET    /api/v1/background_processes         what is running now
#   POST   /api/v1/background_processes         start it, or step it if it is already there
#   PATCH  /api/v1/background_processes/:key    the same thing, key in the path
#   DELETE /api/v1/background_processes/:key    clear it; unknown keys say ok
#
# A PATCH for a key that was cleared, or never existed, STARTS one. A long run
# whose chip was swiped away mid-flight puts it back on its next step, rather
# than reporting into nothing for twenty minutes because a stale delete won a
# race it never knew it was in.
class Api::V1::BackgroundProcessesController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token

  PERMITTED = %i[key name state detail current total url source].freeze

  # Links arrive as a list of objects, which strong parameters will not take
  # from a bare permit list. A form-encoded caller has no way to send a nested
  # array at all, so a JSON string is accepted there and parsed below.
  PERMITTED_LINKS = { links: [:label, :url] }.freeze

  def index
    render_json(processes: live.map(&:serialize))
  end

  def create
    upsert
  end

  def update
    upsert
  end

  def destroy
    key = params[:key].to_s
    cleared = BackgroundProcess.clear!(user: subject, key: key)
    render_json(key: key, cleared: cleared.present?)
  end

  private

  # A local script authenticating with the shared secret is the Mac talking
  # about its own work - the same credential it already posts messages with, so
  # a watcher does not need an API key provisioned before it can say what it is
  # doing. Everything else still has to be somebody.
  def authorize_user
    return if byte_local?

    super
  end

  def byte_local?
    @byte_local ||= ByteLocal.valid_secret?(request.headers["X-Byte-Secret"])
  end

  # Whose strip this lands on. A secret-authenticated caller may name a user;
  # a signed-in one is always themselves, because an API key is not permission
  # to put a chip on somebody else's screen.
  def subject
    @subject ||= (
      if byte_local?
        (params[:user_id].present? && User.find_by(id: params[:user_id])) || User.me
      else
        current_user
      end
    )
  end

  def live
    BackgroundProcess.live_for(subject)
  end

  def upsert
    key = (params[:key].presence || attrs[:key]).to_s
    return render_json(error: "A key is required", status: :unprocessable_entity) if key.blank?

    process = BackgroundProcess.report!(user: subject, key: key, **attrs.except(:key))
    render_json(process: process.serialize)
  rescue ActiveRecord::RecordInvalid => e
    render_json(error: e.record.errors.full_messages.to_sentence, status: :unprocessable_entity)
  end

  # `current` and `total` are counts and arrive as strings from a form-encoded
  # caller, so they are cast here rather than left for the column to guess at.
  # A blank one is dropped rather than written as zero: a report that says
  # nothing about the count is not a report that the count is none.
  def attrs
    @attrs ||= (
      given = params.permit(*PERMITTED, **PERMITTED_LINKS).to_h.symbolize_keys
      [:current, :total].each { |field|
        next unless given.key?(field)

        given[field] = given[field].presence&.to_i
      }
      given[:links] = parsed_links if params[:links].is_a?(String)
      given
    )
  end

  # The model drops anything it cannot use, so a string that is not JSON ends
  # up as no links rather than as an error - the report itself is still good,
  # and refusing the whole thing over a malformed link would lose the progress
  # it was carrying.
  def parsed_links
    JSON.parse(params[:links].to_s)
  rescue JSON::ParserError
    []
  end
end
