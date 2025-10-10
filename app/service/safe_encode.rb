# frozen_string_literal: true

class SafeEncode
  include ::Serviceable

  attributes :obj

  def call
    encode_utf8(obj)
  end

  def encode_utf8(value)
    case value
    when ::String
      safe_encoded_text(value)
    when ::Hash
      value.transform_values { |v| encode_utf8(v) }
    when ::Array
      value.map { |v| encode_utf8(v) }
    else
      value
    end
  end

  def safe_encoded_text(text)
    return if text.nil?

    # Remove null sequences and invalid characters
    # dup below to avoid frozen strings being modified with `force_encoding`
    text.dup.force_encoding(Encoding::UTF_8).gsub(/\0\S{0,3}/, "")
  rescue Encoding::UndefinedConversionError, Encoding::CompatibilityError, ArgumentError => _e
    # Force encoding
    text = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    retry # To remove null sequences
  end
end
