class ReceiveEmailWorker
  include Sidekiq::Worker

  def perform(bucket, filename)
    require "mail"

    content = FileStorage.download(filename, bucket: bucket)
    mail = Mail.new(content)

    attaches = mail.attachments.each_with_object({}) do |attachment, obj|
      FileStorage.upload(attachment.read, filename: attachment.filename)
      cid = attachment.try(:inline_content_id)
      cid ||= attachment.content_id&.then { |c| c[1..-2] }
      obj[cid || attachment.filename] = attachment.filename
    end

    Email.from_mail(mail, attaches)

    # FileStorage.delete(filename, bucket: bucket)
  end
end
