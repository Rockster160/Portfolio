# Notes on one application. Always nested — a note without the job it belongs
# to isn't anything — and always scoped through the current user's jobs, so an
# id from someone else's search 404s rather than loading.
class JobNotesController < ApplicationController
  before_action :authorize_user
  before_action :load_job
  before_action :load_note, only: [:update, :destroy]

  def create
    # The row is the one in the URL. Moving a beat is `update`'s business, and
    # the two forms that create one have no picker on them.
    @note = @job.notes.new(note_params.except(:job_application_id))

    if @note.save
      @job.touch_activity!
      attach_transcript(@note)
    else
      flash[:alert] = @note.errors.full_messages.to_sentence
    end

    redirect_to interview_path(@job)
  end

  # A beat can be MOVED here as well as edited. Mail arriving for a company the
  # board holds more than once is filed on the likeliest of those rows rather
  # than held back, so the wrong row is a thing that happens and retyping the
  # beat onto the right one is not the fix - that leaves two.
  #
  # Both rows are touched and the redirect follows the beat, because the page
  # being read afterwards is the one it is now on.
  def update
    if @note.update(note_params)
      @job.touch_activity!
      @note.job_application.touch_activity! if @note.job_application_id != @job.id
    else
      flash[:alert] = @note.errors.full_messages.to_sentence
    end

    redirect_to interview_path(@note.job_application)
  end

  def destroy
    @note.destroy!
    @job.touch_activity!

    redirect_to interview_path(@job), notice: "Note removed."
  end

  private

  # The recording of the thing just logged, where one came in with it. A
  # conversation and the beat saying it happened are one thing, so they are one
  # submit - see Transcripts::Intake.
  #
  # A beat that saved stays saved. Words that could not be read as a
  # conversation say so and leave the note alone, because the note is the part
  # that was typed and the recording is the part that can be handed over again.
  def attach_transcript(note)
    return if Transcripts::Intake.call(@job, params[:job_transcript], note: note).nil?

    flash[:notice] = "Note added. Working out who was talking in the recording."
  rescue StandardError => e
    Rails.logger.warn("note transcript failed: #{e.class}: #{e.message}")
    flash[:alert] = "The note is saved, but nothing in that could be read as a conversation."
  end

  def load_job
    @job = current_user.job_applications.find(params[:interview_id])
  end

  def load_note
    @note = @job.notes.find(params[:id])
  end

  # An emptied `follow_up_at` arrives as "" and casts to nil on assignment,
  # which is what takes the task back off the calendar.
  #
  # `job_application_id` is checked against the signed-in board rather than
  # trusted: it arrives off a select and it reparents a record, which is the
  # pair that hands one account's beat to another account's row.
  def note_params
    permitted = params.require(:job_note).permit(
      :job_application_id,
      :body,
      :summary,
      :tag,
      :occurred_at,
      :source,
      :url,
      :spoke_to,
      :duration_minutes,
      :follow_up_at,
      *JobNote::SENTIMENT.keys,
    )
    target = permitted[:job_application_id]
    return permitted if target.present? && current_user.job_applications.exists?(id: target)

    permitted.except(:job_application_id)
  end
end
