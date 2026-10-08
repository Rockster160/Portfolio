class ApplicationMailer < ActionMailer::Base
  default from: "contact@ardesian.com"
  layout "mailer"

  # Build and return the outbound message. Going through ActionMailer rather
  # than a bare `Mail.new` is what applies the SMTP settings configured in the
  # production environment — a raw Mail message would try to deliver through
  # nothing. The HTML is passed as the body directly, so no template or layout
  # is rendered: the words were already composed in the editor.
  def compose(from:, to:, subject:, html_body:, attachments: [])
    attachments.each do |file|
      next if file.blank?

      self.attachments[file.original_filename] = file.read
    end

    mail(
      from:         from,
      to:           to,
      subject:      subject,
      content_type: "text/html",
      body:         html_body,
    )
  end
end
