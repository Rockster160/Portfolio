class ApplicationMailer < ActionMailer::Base
  default from: 'contact@ardesian.com'
  layout 'mailer'

  def deliver_email(email_id)
    email = Email.find(email_id).to_mail
    mail(
      to: email.to,
      from: email.from,
      subject: email.subject,
      content_type: "text/html",
      body: email.body.raw_source
    )
  end
end
