# A recording of one conversation with one employer. Always nested under the
# job, always scoped through the current user's jobs — same rule as notes: an
# id from somebody else's search 404s rather than loading.
class JobTranscriptsController < ApplicationController
  before_action :authorize_user
  before_action :load_job
  before_action :load_transcript, only: [:show, :update, :destroy, :sides]

  # The page, or the conversation as data.
  #
  # JSON IS THE LOCAL JOB HUNTER READING THE CORRECTED VERSION. It pulls the
  # questions he was actually asked out of a recording and rebuilds his spoken
  # answers for the answer bank, and the one thing that work needs is which
  # turns are his - which is settled here, on the board, where he can also
  # correct it. It used to work that out again from its own copy of the file,
  # so the same recording was labelled twice by two different passes and the
  # corrected one had to be exported and re-dropped to get back here.
  def show
    respond_to do |format|
      format.html
      format.json { render json: conversation(@transcript) }
    end
  end

  # The whole upload, in one post: the file is read into turns, the file itself
  # is kept, and a pass over the words starts on who was talking. Nothing is
  # ASKED about speakers, here or on the page - dropping the file in is the
  # whole instruction, and what the file needs (a split into sides, or being
  # told which of its own labels is him) is something it can be read off rather
  # than a question for the person who just dropped it.
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
      queue_speakers(@transcript)
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

  # An upload that landed is an upload that landed. A queue that is not there
  # must not turn it into "that file could not be read" - the conversation is
  # on the page either way, and who was talking is the part that is missing.
  def queue_speakers(transcript)
    TranscriptSpeakersWorker.perform_async(transcript.id)
  rescue StandardError => e
    Rails.logger.warn("transcript speakers enqueue failed: #{e.class}: #{e.message}")
  end

  # `who` rather than a name, because that is the question being answered and a
  # name is not an answer to it: `Speaker 2` is nobody, and `Unknown` is two
  # different people. `speaker` rides along as what to CALL them, which is the
  # label where nobody has typed anything better.
  def conversation(transcript)
    {
      id:                 transcript.id,
      title:              transcript.label,
      occurred_at:        transcript.occurred_at,
      company:            @job.company,
      job_application_id: @job.id,
      job_note_id:        transcript.job_note_id,
      turns:              transcript.turns.map { |turn| spoken(transcript, turn) },
    }
  end

  def spoken(transcript, turn)
    label = turn["speaker"].to_s
    {
      who:     side_of(transcript, label),
      speaker: transcript.name_for(label),
      at:      turn["at"],
      to:      turn["to"],
      text:    turn["text"],
    }
  end

  def side_of(transcript, label)
    return :unknown if label == JobTranscript::UNKNOWN || transcript.speakers[label].blank?
    return :me if transcript.mine?(label)

    :them
  end

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
