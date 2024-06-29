class Jarvis::Execute::Email < Jarvis::Execute::Executor
  def archive
    email_id = evalargs

    user.emails.find_by(id: email_id)&.archive
  end
end
