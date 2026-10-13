# A recording of one conversation with one employer. Always nested under the
# job, always scoped through the current user's jobs — same rule as notes: an
# id from somebody else's search 404s rather than loading.
class JobTranscriptsController < ApplicationController
  before_action :authorize_user
  before_action :load_job
  before_action :load_transcript, only: [:show, :update, :destroy]

  def show; end

  # The whole upload, in one post: the file is read into turns and the file
  # itself is kept. Nothing is asked about speakers here — naming them is done
  # on the page that shows the conversation, where there is something to read
  # them against.
  def create
    upload = params[:file]
    return redirect_to(interview_path(@job), alert: "Pick a transcript file first.") if upload.blank?

    @transcript = @job.transcripts.new(transcript_params)
    @transcript.ingest!(upload.tempfile, filename: upload.original_filename)
    @transcript.file.attach(
      io: reread(upload), filename: upload.original_filename,
      content_type: upload.content_type.presence || "text/plain"
    )

    if @transcript.save
      @job.touch_activity!
      redirect_to interview_transcript_path(@job, @transcript)
    else
      redirect_to interview_path(@job), alert: @transcript.errors.full_messages.to_sentence
    end
  rescue StandardError => e
    Rails.logger.warn("transcript upload failed: #{e.class}: #{e.message}")
    redirect_to interview_path(@job), alert: "That file could not be read as a transcript."
  end

  # ONE SUBMIT FOR THE WHOLE PAGE. Naming the speakers and moving individual
  # turns onto the right one are the same job done at two scales, and they are
  # done while reading — so they post together rather than making him save a
  # name, scroll back, and save a turn.
  def update
    @transcript.update!(transcript_params) if params[:job_transcript].present?
    @transcript.rename_speakers!(open_hash(:speakers)) if params[:speakers].present?
    moved = @transcript.reassign!(open_hash(:turns))

    redirect_to interview_transcript_path(@job, @transcript),
      notice: moved.positive? ? "Saved. #{moved} turn#{"s" unless moved == 1} moved." : "Saved."
  end

  def destroy
    @transcript.destroy!
    redirect_to interview_path(@job), notice: "Transcript removed."
  end

  private

  def load_job
    @job = current_user.job_applications.find(params[:interview_id])
  end

  def load_transcript
    @transcript = @job.transcripts.find(params[:id])
  end

  # `ingest!` has already read the tempfile to the end, and an IO at EOF
  # attaches as an empty file — the upload would be on the page, nameable and
  # readable, with nothing behind the download link.
  def reread(upload)
    upload.tempfile.rewind
    upload.tempfile
  end

  # `permit!` because the KEYS are the data: a speaker label is whatever the
  # recorder called them, so there is no list of allowed names to write down.
  # Nothing downstream trusts the shape - `rename_speakers!` reads two fields
  # and `reassign!` only writes against turn indexes that already exist.
  def open_hash(key)
    params[key].respond_to?(:permit!) ? params[key].permit!.to_h : params[key].to_h
  end

  def transcript_params
    return {} if params[:job_transcript].blank?

    params.require(:job_transcript).permit(:title, :occurred_at, :job_note_id)
  end
end
