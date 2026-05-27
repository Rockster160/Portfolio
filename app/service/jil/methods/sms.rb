class Jil::Methods::Sms < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :String)
  end

  # [Sms]
  #   #deliver(Text)::Boolean

  # Naming note: avoid `#send` to keep Ruby's `Object#send` intact for this
  # class.
  def deliver(message)
    phone = @jil.user.phone
    return false if phone.blank? || message.to_s.strip.empty?

    ::SmsWorker.perform_async(phone, message.to_s)
    true
  end
end
