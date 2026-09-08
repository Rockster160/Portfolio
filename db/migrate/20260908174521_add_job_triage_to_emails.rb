class AddJobTriageToEmails < ActiveRecord::Migration[7.1]
  def change
    add_column :emails, :job_triage, :jsonb, default: {}, null: false

    # Partial, because the interesting rows are a rounding error on the table:
    # roughly one in a hundred inbound messages is a beat in the job search, and
    # an index over all 49k would be paying for the 99 to find the 1.
    add_index :emails, [:user_id, :timestamp],
      where: "(job_triage ->> 'job') = 'true'",
      name:  "index_emails_on_job_mail"
  end
end
