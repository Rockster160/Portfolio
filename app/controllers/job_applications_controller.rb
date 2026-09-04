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
    @jobs = surface_interviews(JobSearch.call(filtered_jobs.includes(:notes), @query))
    @counts = current_user.job_applications.group(:status).count
    @live_jobs = current_user.job_applications.live.order(:company).to_a
    @new_job = current_user.job_applications.new
    load_upcoming
  end

  # Newest first. The page is read to answer "where is this now", and the answer
  # is the last thing that happened — putting it at the bottom of a long
  # application means scrolling past the history to find it.
  def show
    @notes = @job.notes.recent.to_a
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

  # A booked interview outranks recency. It's the one thing on this page with a
  # deadline that isn't yours to move, and the wall is sorted by "what touched
  # this most recently", which will happily bury Thursday's interview under an
  # email you sent this morning.
  #
  # Not applied to a search: typing a company is asking "where is X", and the
  # answer to that is the ranking JobSearch just did.
  def surface_interviews(jobs)
    return jobs if @query.present?

    booked, rest = jobs.partition { |job| job.next_interview_at.present? }
    booked.sort_by(&:next_interview_at) + rest
  end

  # Two different obligations, and running them together is what made this
  # fiddly: an interview is an appointment you turn up to, a follow-up is a
  # message you owe. They read differently and they're kept apart, so a booked
  # interview never has to compete for a slot in a list of chases.
  #
  # An interview that has already happened leaves both strips — it's history,
  # and the timeline on the job is where history goes.
  def load_upcoming
    notes = JobNote.follow_ups_for(current_user).includes(:job_application).to_a
    booked, chases = notes.partition(&:scheduled?)
    @interviews = booked.select { |note| note.follow_up_at.future? }
    @follow_ups = chases.first(5)
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
