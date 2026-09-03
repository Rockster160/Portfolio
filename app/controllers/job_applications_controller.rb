# Where a job search lives. One row per place you applied; everything that then
# happened with them is a note underneath, in the order it happened.
#
# The index is deliberately the capture surface as well as the list: the common
# action during a search is "something just happened, write it down", and
# making that a two-page trip is how a tracker stops getting updated by week
# three. Pick the company from the dropdown or type a new one, dump the note,
# done.
class JobApplicationsController < ApplicationController
  before_action :authorize_user
  before_action :load_job, only: [:show, :update, :destroy]

  # `status` filters the wall. Nothing means live — active and offers — which
  # is the "hide the rejected by default" the tracker is supposed to do.
  # `all`, or any single status, opens it back up.
  def index
    @filter = params[:status].presence&.to_s || "live"
    @query = params[:q].to_s.strip
    # Search RANKS, the status chips NARROW, and they compose — JobSearch takes
    # whatever relation the filter left and orders it by how well each row
    # answers the query.
    @jobs = JobSearch.call(filtered_jobs.includes(:notes), @query)
    @counts = current_user.job_applications.group(:status).count
    @live_jobs = current_user.job_applications.live.order(:company).to_a
    @follow_ups = upcoming_follow_ups
    @new_job = current_user.job_applications.new
  end

  def show
    @notes = @job.notes.to_a
    @note = @job.notes.new(occurred_at: Time.current)
  end

  # The one form on the index does both halves of "pick a job, or name a new
  # one, then write the note". Which of the two happened is decided here rather
  # than by the browser, so it still works with the fieldset toggle broken and
  # there is only ever one endpoint to reason about.
  #
  # A company with nothing said about it yet is a perfectly good row — the note
  # is optional here, and required nowhere else.
  def create
    @job = pick_or_build_job
    return redirect_to(interviews_path) if @job.nil?

    note = build_note(@job)
    if note && !note.save
      flash[:alert] = note.errors.full_messages.to_sentence
      return redirect_to interview_path(@job)
    end

    @job.touch_activity!
    redirect_to interview_path(@job), notice: created_notice(@job)
  end

  def update
    if @job.update(job_params)
      respond_to do |format|
        format.html { redirect_to interview_path(@job) }
        format.json { render json: serialize(@job) }
      end
    else
      respond_to do |format|
        format.html {
          flash[:alert] = @job.errors.full_messages.to_sentence
          redirect_to interview_path(@job)
        }
        format.json { render json: { errors: @job.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    @job.destroy!

    redirect_to interviews_path, notice: "Removed #{@job.company}."
  end

  private

  def load_job
    @job = current_user.job_applications.find(params[:id])
  end

  # An id from the dropdown wins; otherwise the typed company becomes a new
  # application. Nil means the new one wouldn't save, and the caller bails.
  def pick_or_build_job
    chosen = current_user.job_applications.find_by(id: params[:job_application_id])
    return chosen if chosen

    job = current_user.job_applications.new(job_params)
    return job if job.save

    flash[:alert] = job.errors.full_messages.to_sentence
    nil
  end

  def created_notice(job)
    job.previously_new_record? ? "Tracking #{job.company}." : "Added to #{job.company}."
  end

  def filtered_jobs
    scope = current_user.job_applications.ordered
    return scope if @filter == "all"
    return scope.where(status: @filter) if JobApplication.statuses.key?(@filter)

    scope.live
  end

  # The next things you owe someone, across every application. Nothing else
  # gathers these — each one is a task on the calendar, which answers "what's
  # today" but not "what am I chasing".
  def upcoming_follow_ups
    JobNote.follow_ups_for(current_user).limit(5).includes(:job_application).to_a
  end

  # The index's one form does both jobs at once, so the note fields arrive
  # alongside the application's — and they arrive whether or not anybody filled
  # them in. Nothing written and no tag chosen means they only wanted the
  # company. Picking a tag is itself the note, though: "Applied", on a date,
  # says everything without a sentence under it.
  def build_note(job)
    attrs = note_params
    tagged = attrs[:tag].present? && attrs[:tag].to_s != "note"
    return nil if attrs[:body].to_s.strip.blank? && !tagged

    job.notes.new(attrs)
  end

  def job_params
    params.require(:job_application).permit(
      :company,
      :role,
      :status,
      :color,
      :logo,
      :source,
      :url,
    )
  end

  def note_params
    return {} if params[:job_note].blank?

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

  def serialize(job)
    {
      id:         job.id,
      company:    job.company,
      role:       job.role,
      status:     job.status,
      color:      job.color,
      logo:       job.logo,
      source:     job.source,
      url:        job.url,
      note_count: job.notes.size,
    }
  end
end
