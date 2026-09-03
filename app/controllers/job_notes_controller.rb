# Notes on one application. Always nested — a note without the job it belongs
# to isn't anything — and always scoped through the current user's jobs, so an
# id from someone else's search 404s rather than loading.
class JobNotesController < ApplicationController
  before_action :authorize_user
  before_action :load_job
  before_action :load_note, only: [:update, :destroy]

  def create
    @note = @job.notes.new(note_params)

    if @note.save
      @job.touch_activity!
    else
      flash[:alert] = @note.errors.full_messages.to_sentence
    end

    redirect_to interview_path(@job)
  end

  def update
    if @note.update(note_params)
      @job.touch_activity!
    else
      flash[:alert] = @note.errors.full_messages.to_sentence
    end

    redirect_to interview_path(@job)
  end

  def destroy
    @note.destroy!
    @job.touch_activity!

    redirect_to interview_path(@job), notice: "Note removed."
  end

  private

  def load_job
    @job = current_user.job_applications.find(params[:interview_id])
  end

  def load_note
    @note = @job.notes.find(params[:id])
  end

  # An emptied `follow_up_at` arrives as "" and casts to nil on assignment,
  # which is what takes the task back off the calendar.
  def note_params
    params.require(:job_note).permit(
      :body,
      :tag,
      :occurred_at,
      :source,
      :url,
      :spoke_to,
      :duration_minutes,
      :follow_up_at,
    )
  end
end
