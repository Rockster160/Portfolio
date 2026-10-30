# A recording of one conversation with one employer. Always nested under the
# job, always scoped through the current user's jobs — same rule as notes: an
# id from somebody else's search 404s rather than loading.
class JobTranscriptsController < ApplicationController
  before_action :authorize_user
  before_action :load_job
  before_action :load_transcript, only: [:show, :update, :destroy, :tidy, :debrief]

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

  # The whole upload, in one post: the words are read into turns, kept as a
  # file, and a pass over them starts on who was talking. Nothing is ASKED
  # about speakers, here or on the page - handing the recording over is the
  # whole instruction, and what it needs (a split into sides, or being told
  # which of its own labels is him) is something it can be read off rather than
  # a question for the person who just dropped it.
  #
  # A FILE OR A PASTE, and the one place that tells them apart is `Intake`.
  def create
    @transcript = Transcripts::Intake.call(@job, params[:job_transcript])
    if @transcript.nil?
      alert = "Pick a transcript file, or paste the words in."
      return redirect_to(interview_path(@job), alert: alert)
    end

    @job.touch_activity!
    redirect_to interview_transcript_path(@job, @transcript)
  rescue StandardError => e
    Rails.logger.warn("transcript upload failed: #{e.class}: #{e.message}")
    redirect_to interview_path(@job), alert: "Nothing in that could be read as a conversation."
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

  # Another pass over the words, asked for rather than repeated.
  #
  # It runs by itself when a recording lands, and the press is for the two
  # times that is not enough: the pass read the words before he had corrected
  # who was talking, and a conversation whose terms it did not know came back
  # with the same mishearing in thirty places. Both are better on a second
  # reading, and neither is worth paying for on every page load.
  def tidy
    TranscriptTidyWorker.perform_async(@transcript.id, true)
    redirect_to interview_transcript_path(@job, @transcript),
      notice: "Going back over the words. The page will say when it is done."
  rescue StandardError => e
    Rails.logger.warn("transcript tidy enqueue failed: #{e.class}: #{e.message}")
    redirect_to interview_transcript_path(@job, @transcript),
      alert: "That could not be started just now."
  end

  # How the conversation went, read back to him.
  #
  # It runs by itself once a recording has been split and its words mended, and
  # the press is for after he has corrected either of those: a reading that did
  # not know which half of the conversation was his, or one written off words
  # the recorder got wrong, is a reading of an interview he did not have.
  #
  # `true` because pressing it is the whole instruction - `Debrief.call`
  # refuses a recording it has already read unless it is asked twice.
  def debrief
    TranscriptDebriefWorker.perform_async(@transcript.id, true)
    redirect_to interview_transcript_path(@job, @transcript),
      notice: "Reading it back. The page will say when it is done."
  rescue StandardError => e
    Rails.logger.warn("transcript debrief enqueue failed: #{e.class}: #{e.message}")
    redirect_to interview_transcript_path(@job, @transcript),
      alert: "That could not be started just now."
  end

  def destroy
    @transcript.destroy!
    redirect_to interview_path(@job), notice: "Transcript removed."
  end

  private

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
