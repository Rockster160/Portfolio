# The job's id in the LOCAL job hunter, which is the other half of a pointer
# that only ever existed in one direction: jobhunt stamps `rails_job_id` on its
# own row the moment the board accepts one, so it can link out to
# ardesian.com/interviews/N, and nothing here could link back.
#
# The posting on the board is the EMPLOYER's page - a Greenhouse or LinkedIn url
# that is often dead weeks later. The local page is the working copy: the
# description as it was scraped, the score and why, the questions already
# answered, the letter. That is the page worth opening while reading a timeline,
# and finding it meant searching jobhunt by company.
class AddJobhuntJobIdToJobApplications < ActiveRecord::Migration[7.1]
  def change
    add_column :job_applications, :jobhunt_job_id, :integer
  end
end
