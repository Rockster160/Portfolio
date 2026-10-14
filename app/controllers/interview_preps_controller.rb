# The brief for one interview. Nested under the job and scoped through the
# current user's applications — same rule as notes and transcripts: an id from
# somebody else's search 404s rather than loading.
#
# Read and delete only. A brief is written by the session an hour before the
# interview (ByteInterviewPrep); there is no form behind it, and the only thing
# to do with a bad one is get rid of it.
class InterviewPrepsController < ApplicationController
  before_action :authorize_user
  before_action :load_job
  before_action :load_prep

  def show; end

  def destroy
    @prep.destroy!
    redirect_to interview_path(@job), notice: "Prep removed."
  end

  private

  def load_job
    @job = current_user.job_applications.find(params[:interview_id])
  end

  def load_prep
    @prep = @job.preps.find(params[:id])
  end
end
