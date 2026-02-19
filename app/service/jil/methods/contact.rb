class Jil::Methods::Contact < Jil::Methods::Base
  PERMIT_ATTRS = [:name, :nickname, :username, :permit_relay, :phone, :data].freeze

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
  #   #contact_relay(String content(...))::Boolean
  #   .name::String
  #   .nickname::String
  #   .username::String
  #   .permitRelay?::Boolean
  #   .phone::String
  #   .data::Hash
  #   .update!(content(ContactData))
  #   .relay(content(...))::Boolean
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

  # Relay sends data to a friend's Jil tasks, triggering any tasks they have
  # listening for :relay events. The friend must have permit_relay enabled on
  # their contact entry for you (bidirectional trust). A `from` key with your
  # username is automatically merged into the data payload.
  #
  # Returns true if the relay was sent, false if the friend wasn't found or
  # relay isn't permitted.
  #
  # Class method - look up contact by name/username/alias:
  #   Contact.relay("Alice", {action: "unlock", code: "1234"})
  #
  # Instance method - relay to an already-resolved contact:
  #   alice = Contact.find("Alice")
  #   alice.relay({action: "unlock", code: "1234"})

  def contact_relay(name, data)
    friend = @jil.user.contacts.name_find(name)&.friend if name.is_a?(::String)
    friend ||= @jil.user.contacts.find_by(id: name[:id])&.friend if name.is_a?(::Hash)

    return false if friend&.contacts&.where(friend_id: @jil.user.id, permit_relay: true).blank?

    ::Jil.trigger_now(friend, :relay, @jil.cast(data, :Hash).merge(from: @jil.user.username))
    true
  end

  def relay(contact, data)
    friend = @jil.user.contacts.find_by(id: contact[:id])&.friend

    return false if friend&.contacts&.where(friend_id: @jil.user.id, permit_relay: true).blank?

    ::Jil.trigger_now(friend, :relay, @jil.cast(data, :Hash).merge(from: @jil.user.username))
    true
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
