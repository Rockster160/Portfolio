class DeleteReolinkEmails < ActiveRecord::Migration[7.1]
  def up
    Email.where("text_body ILIKE '% has detected a%'").find_each(&:destroy)
  end
end
