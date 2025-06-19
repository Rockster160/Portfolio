# frozen_string_literal: true

class Emails::ParseMail
  include ::Memoizable, ::Serviceable
  attributes :mail, params: {}

  def call
    self # return self for chaining
  end

  💾(:mailboxes) {
    {
      to:       ::Emails::Normalizer.mailboxes(params[:to], *mail[:to]&.addrs),
      from:     ::Emails::Normalizer.mailboxes(params[:from], *mail[:from]&.addrs),
      cc:       ::Emails::Normalizer.mailboxes(params[:cc], *mail[:cc]&.addrs),
      bcc:      ::Emails::Normalizer.mailboxes(params[:bcc], *mail[:bcc]&.addrs),
      reply_to: ::Emails::Normalizer.mailboxes(params[:reply_to], *mail[:reply_to]&.addrs),
    }
  }
  💾(:to) { mailboxes[:to] + mailboxes[:cc] }
  💾(:from) { mailboxes[:from] }
  💾(:message_id) { mail.message_id.presence }
  💾(:thread_ids) {
    ::Emails::Normalizer.thread_ids(
      params[:in_reply_to],
      params[:thread_id],
      params[:thread_ids],
      mail.in_reply_to,
      mail.references,
      mail[:thread_id],
      message_id,
    )
  }
  💾(:failed_delivery?) { flat_parts.any? { |part| part.mime_type == "message/delivery-status" } }
  💾(:text_part) { parts[:text] }
  💾(:html_part) { parts[:html] }
  💾(:parts) { extracted_parts }
  💾(:flat_parts) { ::Array.wrap(flatten_parts(extract_parts(mail))) }
  💾(:extracted_parts) {
    has_html = flat_parts.any? { |part| part.mime_type == "text/html" }
    # If there is an HTML part, we assume the HTML contains the entire email.
    # In that case, we remove the html part and build the text parts from the rest.
    # If there isn't an HTML part, we build the parts separately,
    #   making sure to include images in the generated HTML

    parts_hash = { text: [], html: [] }
    parts_hash.each_key { |key|
      mime = key == :text ? :plain : :html
      target_parts = flat_parts.select { |part| part.mime_type == "text/#{mime}" } if has_html

      parts_hash[key] = (target_parts.presence || flat_parts).map { |part|
        extracted_part = key == :text ? part_text(part) : part_html(part)
        ::SafeEncode.call(extracted_part)
      }.reject(&:blank?).join
    }
  }
  💾(:attachments) { mail.attachments || [] }

  private

  def extract_parts(part)
    part.try(:parts).present? ? part.parts : part
  end

  def flatten_parts(part_group)
    return part_group unless part_group.is_a?(::Array) || part_group.is_a?(::Mail::PartsList)

    part_group.map { |part|
      next if part.mime_type.nil? # Empty parts can sometimes be passed: filter them out.

      flatten_parts(extract_parts(part)).presence || part
    }.flatten.compact
  end

  def part_text(part)
    return if part.mime_type.nil? # Technically an invalid email
    return part_text_image(part) unless part.mime_type.starts_with?("text/")
    return decode_part(part) if part.mime_type == "text/plain"

    ::Emails::Normalizer.email_text(decode_part(part))
  end

  def part_html(part)
    return if part.mime_type.nil? # Technically an invalid email
    return part_html_image(part) unless part.mime_type.starts_with?("text/")

    decode_part(part)&.then { |str|
      part.mime_type == "text/plain" ? text_to_html(str) : str
    }
  end

  def text_to_html(text)
    ::CGI.escapeHTML(text).gsub(/\[image: ?([^\]]*?)\]/) {
      filename_to_img(::Regexp.last_match(1))
    }.gsub(/(\r?\n\r?)/, "<br/>")
  end

  def filename_to_img(filename)
    "<img src=\"cid:#{filename}\" alt=\"#{filename}\" />"
  end

  def part_text_image(part)
    return unless part.mime_type.starts_with?("image/")

    "[image: #{part.filename}]"
  end

  def part_html_image(part)
    return unless part.mime_type.starts_with?("image/")

    filename_to_img(part.filename)
  end

  def decode_part(part)
    str = part.respond_to?(:body) ? part.body.decoded : part.decoded
    str = decode_encoding(str, :base64) { |part_str|
      part_str = part_str.gsub(/Content-ID: <.*?>/, "")
      ::Mail::Encodings::Base64.decode(part_str).strip
    }
    str = decode_encoding(str, "7bit") { |part_str|
      ::SafeEncode.call(part_str).strip
    }
    decode_encoding(str, /quoted-?printable/) { |part_str|
      ::Mail::Encodings::QuotedPrintable.decode(part_str).strip
    }
  end

  def decode_encoding(str, encoding, &block)
    return str unless str.match?(/Content-Transfer-Encoding: #{encoding}/i)

    extra_content_options = /(?:[\r\n\s]*Content[^\n\r]*?:[^\n\r]*[\r\n\s]+)*/im
    _, postencode = str.split(/Content-Transfer-Encoding: #{encoding}#{extra_content_options}/i, 2)

    block.call(postencode)
  end
end
