class ApplicationMailer < ActionMailer::Base
  default from: "contact@ardesian.com"
  layout "mailer"

  def deliver_email(email_id, attaches=[])
    email = ::Email.find(email_id).to_mail
    attaches&.each do |attachment|
      next if attachment.blank?

      attachments[attachment.original_filename] = attachment.read
    end

    mail(
      to:           email.to,
      from:         email.from,
      subject:      email.subject,
      content_type: "text/html",
      body:         email.body.raw_source,
    )
  end
end
