# The brief for one interview. Nested under the job and scoped through the
# current user's applications — same rule as notes and transcripts: an id from
# somebody else's search 404s rather than loading.
#
# A brief is written by the session an hour before the interview
# (ByteInterviewPrep) rather than typed, so there is nothing to create. It is
# his to change once it is here though: a fact about the company comes out
# wrong, or something said in the call belongs in it before the next round.
class InterviewPrepsController < ApplicationController
  before_action :authorize_user
  before_action :load_job
  before_action :load_prep

  def show; end

  # Whatever he typed, kept as typed. The body is markdown read by skimming
  # headings, and reformatting an edit on the way in would fight the person
  # making it.
  def update
    if @prep.update(prep_params)
      redirect_to interview_prep_path(@job, @prep), notice: "Prep saved."
    else
      redirect_to interview_prep_path(@job, @prep),
        alert: @prep.errors.full_messages.to_sentence
    end
  end

  def destroy
    @prep.destroy!
    redirect_to interview_path(@job), notice: "Prep removed."
  end

  private

  # `interview_at` is not on the list: it is the booking the brief was written
  # for, and the agenda row is what says when that is.
  def prep_params
    params.require(:interview_prep).permit(:title, :kind, :body)
  end

  def load_job
    @job = current_user.job_applications.find(params[:interview_id])
  end

  def load_prep
    @prep = @job.preps.find(params[:id])
  end
end
