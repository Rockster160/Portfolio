class Jil::Methods::Contact < Jil::Methods::Base
  PERMIT_ATTRS = [:name, :nickname, :username, :permit_relay, :phone, :data]

  def cast(value)
    case value
    when ::Contact then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else ::SoftAssign.call(::Contact.new, @jil.cast(value, :Hash))
    end
  end

  # [Contact]
  #   #find(String|Numeric)
  #   #search(String)::Array
  #   #create(content(ContactData))
  #   .name::String
  #   .nickname::String
  #   .username::String
  #   .permitRelay?::Boolean
  #   .phone::String
  #   .data::Hash
  #   .update!(content(ContactData))
  #   .get(String)::Any
  #   .set!(String " : " Any)
  # *[ContactData]
  #   #name(String)
  #   #nickname(String)
  #   #username(String)
  #   #permitRelay?(Boolean)
  #   #phone(String)
  #   #data(content(Hash))

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case method_sym
    when :id, *PERMIT_ATTRS
      case token_class(line.objname)
      when :Contact
        token_val(line.objname)[method_sym]
      when :ContactData
        send(method_sym, *evalargs(line.args))
      end
    else fallback(line)
    end
  end

  def find(name)
    found = @jil.user.contacts.find_by(id: name) if name.match?(/^\d+$/)
    found ||= @jil.user.contacts.name_find(name)
    found
  end

  def search(name)
    @jil.user.contacts.search(name)
  end

  def create(details)
    @jil.user.contacts.create(params(details))
  end

  def update!(contact, details)
    @jil.user.contacts.find(contact[:id]).tap { |c|
      c.update(params(details))
    }
  end

  def get(contact, key)
    @jil.user.contacts.find(contact[:id]).data[key]
  end

  def set!(contact, key, value)
    @jil.user.contacts.find(contact[:id]).tap { |c| c.update(data: c.data.merge({ key => value })) }
  end

  # [ContactData]

  def name(text)
    { name: text }
  end

  def nickname(text)
    { nickname: text }
  end

  def username(text)
    { username: text }
  end

  def permit_relay(bool)
    { permit_relay: bool }
  end

  def phone(text)
    { phone: text }
  end

  def data(details={})
    { data: details }
  end

  private

  def params(details)
    @jil.cast(details, :Hash).slice(*PERMIT_ATTRS).tap { |obj|
      obj[:data] = @jil.cast(obj[:data], :Hash) if obj.key?(:data)
    }
  end
end
