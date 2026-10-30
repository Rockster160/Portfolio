# The recorder's door, and the recordings nobody has filed yet.
#
# Separate from JobTranscriptsController because that one is nested under an
# application and every action on it starts by loading the job. These are the
# recordings that do not have one: they arrive off the laptop the moment a call
# ends, and which interview they were — if any — is settled afterwards.
#
# THE RECORDER SENDS WORDS, NEVER AUDIO. Nothing here takes a file. An hour of
# two streams is a few hundred megabytes of something that has never once been
# wanted after the fact, so the laptop transcribes, uploads the words, and
# deletes the recording itself.
class TranscriptsController < ApplicationController
  before_action :authorize_user
  before_action :load_transcript, only: [:attach, :skip, :destroy]

  # A call that has just ended, posted by the recorder with an API key.
  #
  # The reply carries the skip list every time. The recorder has no settings of
  # its own and nothing on the laptop to edit — this is the one moment it is
  # certainly talking to the board, so it is where it finds out what it is not
  # supposed to record any more.
  def create
    transcript = Transcripts::Arriving.call(current_user, recording_params)
    if transcript.nil?
      return render(json: { error: "nothing in that could be read" }, status: :unprocessable_entity)
    end

    render json: {
      id:    transcript.id,
      filed: filed_as(transcript),
      skip:  RecordingSkip.keys_for(current_user),
    }
  end

  # What the recorder asks for when it starts up, so a source denied while it
  # was not running is denied before the next call rather than after it.
  def skips
    render json: { skip: RecordingSkip.keys_for(current_user) }
  end

  # Filed by hand, which the clock could not do: it found nothing, or it found
  # two interviews an hour apart and would have had to guess between them.
  #
  # The booking is optional — a conversation that was never written down is
  # still a conversation with that company, and the recording is worth having
  # on the application either way. Filing it is what starts the read of how it
  # went; that pass refuses an unfiled recording, because it has no company,
  # role or timeline to read the conversation against.
  def attach
    application = current_user.job_applications.find(params[:interview_id])
    @transcript.file!(application, note: booking(application))
    queue_debrief(@transcript)

    redirect_to interview_transcript_path(application, @transcript),
      notice: "Filed on #{application.company}. Reading it back now."
  rescue ActiveRecord::RecordNotFound
    redirect_to interviews_path, alert: "That interview could not be found."
  end

  # Thrown away, and nothing from that source recorded again. One press rather
  # than two, because they are the same decision: the reason this recording is
  # junk is where it came from.
  def skip
    skipped = RecordingSkip.from!(@transcript)
    @transcript.destroy!

    said = skipped ? "Deleted. Not recording from #{skipped.label_or_key} any more." : "Deleted."
    redirect_to interviews_path, notice: said
  end

  def destroy
    @transcript.destroy!
    redirect_to interviews_path, notice: "Recording deleted."
  end

  # Recording from somewhere again. The list has to be undoable from the page
  # or one wrong press is permanent and invisible.
  def unskip
    skip = current_user.recording_skips.find_by(id: params[:skip_id])
    skip&.destroy!

    redirect_to interviews_path, notice: "Recording from there again."
  end

  private

  # The booking it names, or the one the clock suggests. Scoped through the
  # application it is being filed onto, so a note id from somewhere else never
  # lands on it.
  def booking(application)
    given = params[:job_note_id].presence
    return application.notes.find_by(id: given) if given

    Transcripts::Filing.candidates(@transcript).find { |note|
      note.job_application_id == application.id
    }
  end

  def filed_as(transcript)
    return nil unless transcript.filed?

    { company: transcript.job_application.company, interview_id: transcript.job_application_id }
  end

  def queue_debrief(transcript)
    TranscriptDebriefWorker.perform_async(transcript.id)
  rescue StandardError => e
    Rails.logger.warn("transcript debrief enqueue failed: #{e.class}: #{e.message}")
  end

  # Only ever his own, and only ever one nobody has filed — a filed recording
  # is reached through its application, where deleting it is already offered.
  def load_transcript
    @transcript = JobTranscript.unfiled.where(user: current_user).find(params[:id])
  end

  def recording_params
    params.require(:recording).permit(
      :started_at,
      :title,
      source:   [:app, :bundle, :host, :url],
      segments: [:who, :at, :to, :text],
    )
  end
end
