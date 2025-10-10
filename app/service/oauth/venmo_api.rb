# _scripts/oauth/venmo_oauth.rb
# Used the above to generate keys and everything

# ::Oauth::VenmoApi.new(User.me).get(:me)
# ::Oauth::VenmoApi.new(User.me).get("payment-methods")
# ::Oauth::VenmoApi.new(User.me).send_by_name("Mom", 20, "🥩")
# ::Oauth::VenmoApi.new(User.me).send_by_name("B", 1, "Test")
# ::Oauth::VenmoApi.new(User.me).request_by_name("B", 1, "Test")

# o.get(:me)
# {:data=>
#   {:user=>
#    :balance=>"10.00",

class Oauth::VenmoApi < Oauth::Base
  include ::ActionView::Helpers::NumberHelper

  VENMO_BALANCE_ID = 1_653_332_309_442_560_599
  MACU_ID = 1_653_333_114_748_928_453
  CHASE_ID = 4_195_446_905_898_258_092
  constants(api_url: "https://api.venmo.com/v1")

  # ========== Via Name ==========
  def send_by_name(name, amount, note)
    send_money(venmo_id_from_name(name), amount, note)
  end

  def request_by_name(name, amount, note)
    request_money(venmo_id_from_name(name), amount, note)
  end

  def charge_by_name(name, amount, note)
    charge_money(venmo_id_from_name(name), amount, note)
  end

  # ========== Via Contact ==========
  def send_to_contact(contact, amount, note)
    send_money(venmo_id_from_contact(contact), amount, note)
  end

  def request_from_contact(contact, amount, note)
    request_money(venmo_id_from_contact(contact), amount, note)
  end

  def charge_contact(contact, amount, note)
    charge_money(venmo_id_from_contact(contact), amount, note)
  end

  # ========== Via Venmo User ID ==========
  def send_money(id, amount, note) = charge_money(id, amount.abs, note)
  def request_money(id, amount, note) = charge_money(id, -(amount.abs), note)

  # positive = send money
  # negative = request money
  def charge_money(id, amount, note, source: :venmo)
    return "Venmo: No id found!" if id.blank?

    if Rails.env.production?
      post(:payments, {
        user_id:  id,
        note:     note,
        amount:   amount,
        metadata: { quasi_cash_disclaimer_viewed: true },
        audience: :public,
      }.tap { |params|
        if amount.positive?
          params[:funding_source_id] = source == :venmo ? VENMO_BALANCE_ID : CHASE_ID
        end
      }).tap { |res|
        if res&.dig(:data, :error_code).present?
          if source == :venmo
            Jarvis.say("Venmo via balance failed. Trying via bank...")
            return charge_money(id, amount, note, source: :bank)
          else
            MeCache.set(:venmo_error, res)
            return "Failed to Venmo! Error stored in cache(venmo_error)"
          end
        end
      }
    end

    message(id, amount, note)
  end

  # ========== Helpers ==========
  def contact_mapping
    @contact_mapping ||= cache_get(:contact_ids) || {}
  end

  def message(id, amount, note)
    if amount.positive?
      "Paying #{id_to_name(id)} #{amount_to_currency(amount)} for #{note}"
    else
      "Requesting #{amount_to_currency(amount.abs)} from #{id_to_name(id)} for #{note}"
    end
  end

  def amount_to_currency(amount)
    number_to_currency(amount).gsub(".00", "")
  end

  def id_to_name(id)
    contact_id = contact_mapping.key(id)
    Contact.find(contact_id.to_s).name
  end

  def contact_by_name(name)
    @user.address_book.contact_by_name(name).tap { |contact|
      Jarvis.ping("Unknown contact: '#{name}'.") if contact.nil?
    }
  end

  def venmo_id_from_name(name)
    venmo_id_from_contact(contact_by_name(name))
  end

  def search(name)
    return if name.blank?

    # Should paginate this
    get(:users, { query: name })[:data].then { |users|
      break users.first if users.length == 1

      users.select { |user|
        user[:friend_status]&.to_sym == :friend
      }&.then { |d| d.first if d.length == 1 }
    }
  end

  def venmo_id_from_contact(contact)
    return if contact.blank?

    venmo_id = contact_mapping[contact.id.to_s.to_sym]
    return venmo_id if venmo_id.present?

    Jarvis.say("Searching for #{contact.name} in Venmo.")

    user = search(contact.raw[:name])
    user ||= search(contact.name)
    user ||= search(contact.nickname)
    return Jarvis.ping("Unable to find Venmo id for #{contact.name}.") if user.blank?

    contact_mapping.merge!(contact.id => user[:id])
    cache_set(:contact_ids, contact_mapping)
    user[:id]
  end
end
