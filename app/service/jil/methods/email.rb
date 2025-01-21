class Jil::Methods::Email < Jil::Methods::Base
  def cast(value)
    case value
    when ::Email then value.as_json(only: [:id, :from, :to, :subject])
    else @jil.cast(value, :Hash)
    end
  end

  def find(id)
    @jil.user.emails.find(id)
  end

  def search(q, limit, order)
    limit = (limit.presence || 50).to_i.clamp(1..100)
    scoped = @jil.user.emails.query(q).page(1).per(limit)
    scoped = scoped.order(created_at: order) if [:asc, :desc].include?(order.to_s.downcase.to_sym)
    scoped.map(&:legacy_serialize)
  end

  def to(email_data)
    email(email_data).to
  end

  def from(email_data)
    email(email_data).from
  end

  def subject(email_data)
    email(email_data).subject
  end

  def text(email_data)
    email(email_data).text_body
  end

  def html(email_data)
    email(email_data).html_body
  end

  def timestamp(email_data)
    email(email_data).created_at
  end

  def archive(email_data, boolean)
    email(email_data).archive(boolean)
  end

  private

  def email(email_data)
    @jil.user.emails.find(cast(email_data)[:id])
  end
end
