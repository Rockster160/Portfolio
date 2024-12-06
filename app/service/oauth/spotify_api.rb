class Oauth::SpotifyApi < Oauth::Base
  include ::ActionView::Helpers::NumberHelper

  constants(
    # oauth_url: "https://accounts.spotify.com/authorize",
    # api_url: xxxx "https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/",
    # exchange_url: xxx "https://auth.tesla.com/oauth2/v3/token",
    scopes: %w[user-read-playback-state user-modify-playback-state user-read-currently-playing],
  )

  # constants(api_url: "https://api.spotify.com/v1")

  # # ========== Via Name ==========
  # def send_by_name(name, amount, note)
  #   send_money(spotify_id_from_name(name), amount, note)
  # end
  # def request_by_name(name, amount, note)
  #   request_money(spotify_id_from_name(name), amount, note)
  # end
  # def charge_by_name(name, amount, note)
  #   charge_money(spotify_id_from_name(name), amount, note)
  # end

  # # ========== Via Contact ==========
  # def send_to_contact(contact, amount, note)
  #   send_money(spotify_id_from_contact(contact), amount, note)
  # end
  # def request_from_contact(contact, amount, note)
  #   request_money(spotify_id_from_contact(contact), amount, note)
  # end
  # def charge_contact(contact, amount, note)
  #   charge_money(spotify_id_from_contact(contact), amount, note)
  # end

  # # ========== Via Spotify User ID ==========
  # def send_money(id, amount, note) = charge_money(id, amount.abs, note)
  # def request_money(id, amount, note) = charge_money(id, -(amount.abs), note)
  # # positive = send money
  # # negative = request money
  # def charge_money(id, amount, note, source: :spotify)
  #   return "Spotify: No id found!" if id.blank?

  #   if Rails.env.production?
  #     post(:payments, {
  #       user_id: id,
  #       note: note,
  #       amount: amount,
  #       metadata: { quasi_cash_disclaimer_viewed: true },
  #       audience: :public,
  #     }.tap { |params|
  #       if amount.positive?
  #         params[:funding_source_id] = source == :spotify ? spotify_BALANCE_ID : CHASE_ID
  #       end
  #     }).tap { |res|
  #       if res&.dig(:data, :error_code).present?
  #         if source == :spotify
  #           Jarvis.say("Spotify via balance failed. Trying via bank...")
  #           return charge_money(id, amount, note, source: :bank)
  #         else
  #           MeCache.set(:spotify_error, res)
  #           return "Failed to Spotify! Error stored in cache(spotify_error)"
  #         end
  #       end
  #     }
  #   end

  #   message(id, amount, note)
  # end

  # # ========== Helpers ==========
  # def contact_mapping
  #   @contact_mapping ||= cache_get(:contact_ids) || {}
  # end

  # def message(id, amount, note)
  #   if amount.positive?
  #     "Paying #{id_to_name(id)} #{amount_to_currency(amount)} for #{note}"
  #   else
  #     "Requesting #{amount_to_currency(amount.abs)} from #{id_to_name(id)} for #{note}"
  #   end
  # end

  # def amount_to_currency(amount)
  #   number_to_currency(amount).gsub(".00", "")
  # end

  # def id_to_name(id)
  #   contact_id = contact_mapping.key(id)
  #   Contact.find(contact_id.to_s).name
  # end

  # def contact_by_name(name)
  #   @user.address_book.contact_by_name(name).tap { |contact|
  #     Jarvis.ping("Unknown contact: '#{name}'.") if contact.nil?
  #   }
  # end

  # def spotify_id_from_name(name)
  #   spotify_id_from_contact(contact_by_name(name))
  # end

  # def search(name)
  #   return unless name.present?
  #   # Should paginate this
  #   get(:users, { query: name })[:data].then { |users|
  #     break users.first if users.length == 1

  #     users.select { |user|
  #       user[:friend_status]&.to_sym == :friend
  #     }&.then { |d| d.first if d.length == 1 }
  #   }
  # end

  # def spotify_id_from_contact(contact)
  #   return if contact.blank?

  #   spotify_id = contact_mapping[contact.id.to_s.to_sym]
  #   return spotify_id if spotify_id.present?

  #   Jarvis.say("Searching for #{contact.name} in Spotify.")

  #   user = search(contact.raw[:name])
  #   user ||= search(contact.name)
  #   user ||= search(contact.nickname)
  #   return Jarvis.ping("Unable to find Spotify id for #{contact.name}.") unless user.present?

  #   contact_mapping.merge!(contact.id => user[:id])
  #   cache_set(:contact_ids, contact_mapping)
  #   user[:id]
  # end
end
