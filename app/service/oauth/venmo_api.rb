# _scripts/oauth/venmo_oauth.rb
# Used the above to generate keys and everything

# ::Oauth::VenmoApi.new(User.me).send_by_name("Mom", 20, "🥩")

class Oauth::VenmoApi < Oauth::Base
  VENMO_BALANCE_ID = 1653332309442560599
  constants(API_URL: "https://api.venmo.com/v1")

  # ========== Via Name ==========
  def send_by_name(name, amount, note)
    send_money(user_id_from_name(name), amount, note)
  end
  def request_by_name(name, amount, note)
    request_money(user_id_from_name(name), amount, note)
  end
  def charge_by_name(name, amount, note)
    charge_money(user_id_from_name(name), amount, note)
  end

  # ========== Via Contact ==========
  def send_to_contact(contact, amount, note)
    send_money(user_id_from_contact(contact), amount, note)
  end
  def request_from_contact(contact, amount, note)
    request_money(user_id_from_contact(contact), amount, note)
  end
  def charge_contact(contact, amount, note)
    charge_money(user_id_from_contact(contact), amount, note)
  end

  # ========== Via Venmo User ID ==========
  # positive = send money
  # negative = request money
  def send_money(id, amount, note) = charge_money(id, amount.abs, note)
  def request_money(id, amount, note) = charge_money(id, -(amount.abs), note)
  def charge_money(id, amount, note)
    return if id.blank?

    post(:payments, {
      user_id: id,
      note: note,
      amount: amount,
      metadata: { quasi_cash_disclaimer_viewed: true },
      audience: :public,
    }.tap { |params|
      params[:funding_source_id] = VENMO_BALANCE_ID if amount.positive?
    })
  end

  # ========== Helpers ==========
  def contact_mapping
    @contact_mapping ||= cache_get(:contact_mapping) || {}
  end

  def contact_by_name(name)
    @user.address_book.contact_by_name(name)
  end

  def user_id_from_name(name)
    user_id_from_contact(contact_by_name(name))
  end

  def search(name)
    return unless name.present?
    # Should paginate this
    # get(:users, { query: name })[:data].then { |users|
    #   break users.first if users.length == 1
    #
    #   users.select { |user|
    #     user[:friend_status]&.to_sym == :friend
    #   }&.then { |d| d.first if d.length == 1 }
    # }
  end

  def user_id_from_contact(contact)
    return if contact.blank?

    id = contact_mapping[contact.id.to_s]
    return id if id.present?

    Jarvis.ping("Haven't mapped #{contact.name} yet.")
    # TODO: Look up
    #
    # user = search(contact.raw[:name])
    # user ||= search(contact.name)
    # user ||= search(contact.nickname)
    # return unless user.present?
    #
    # contact_mapping.merge!(contact.id => user[:id])
    # cache_set(:contact_ids, contact_mapping)
    # user[:id]
  end
end
