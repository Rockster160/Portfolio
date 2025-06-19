module Emails::Normalizer
  module_function

  def email(address)
    ilike_email(address)&.downcase
  end

  def ilike_email(address)
    return if address.blank?

    special_chars = Regexp.escape("@<>()[]\\/")
    regex = /[^\s#{special_chars}]+@[^\s#{special_chars}]+\.[^\s#{special_chars}]+/

    address[regex].presence
  end

  def strip_plus_code(email_address)
    ilike_email(email_address).to_s.strip.gsub(/\+.*?@/, "@").presence
  end

  def mailbox(mailbox_address) # "Billy Bob <BillyBobJoe@BillysPlace.com>"
    mailbox_obj = (
      case mailbox_address
      when ::Mail::Address then mailbox_address
      when ::Hash then addresses_from_meta(mailbox_address).first
      else ::Mail::Address.new(mailbox_address)
      end
    )

    display_name = (
      if mailbox_obj.display_name.to_s.downcase == mailbox_obj.address.to_s.downcase
        nil
      else
        mailbox_obj.display_name
      end
    )

    {
      name:    display_name.presence,
      address: mailbox_obj.address.presence, # Does NOT format/normalize the email address!
    }.compact
  end

  def mailboxes(*email_addresses)
    ::Array.wrap(email_addresses).flatten.filter_map { |email_address|
      mailbox(email_address)
    }.compact_blank.uniq { |detail|
      ::Emails::Normalizer.email(detail[:address])
    }
  end

  def addresses_from_meta(*recipients)
    ::Array.wrap(recipients).flatten.uniq { |recipient|
      ::Emails::Normalizer.email(recipient[:address])
    }.compact.map { |recipient|
      ::Mail::Address.new(recipient[:address]).tap { |mailbox_obj|
        mailbox_obj.display_name = recipient[:name]
      }
    }
  end

  def subject(subject_line)
    return "" if subject_line.blank?

    subject_prefixes = /^((?:RE|FWD|FW|R): ?)+/i

    subject_line.to_s.sub(subject_prefixes, "").strip
  end

  def thread_ids(*possible_thread_ids)
    ::Array.wrap(possible_thread_ids).flatten.compact.filter_map { |possible_thread_id|
      next thread_ids(possible_thread_id) if possible_thread_id.is_a?(::Array)

      if possible_thread_id.to_s.starts_with?("[")
        safe_json_parse(possible_thread_id)
      else
        possible_thread_id
      end
    }.flatten.uniq
  end

  def email_text(html)
    body_html = (::Nokogiri::HTML(html).at("body")&.inner_html&.presence || html&.presence || "")
      .gsub("<br>", "\n")
      .gsub("<br/>", "\n")
      .gsub("<br />", "\n")

    ::ActionView::Base.full_sanitizer.sanitize(body_html)
      .tr("\u00A0", " ")
      .strip
      .tr("\t", " ")
      .squeeze(" ")
      .squeeze("\n")
      .gsub(/\n\s/, "\n")
      .gsub("\r\n", "\n")
      .squeeze("\n")
      .strip
  end

  def safe_json_parse(val)
    return val if val.is_a?(::Hash) || val.is_a?(::Array)

    begin
      ::JSON.parse(val.to_s)
    rescue ::JSON::ParserError
      nil
    end
  end
end
