module RenderHelper
  def hash_table(hash)
    max_key_length = hash.keys.map { |key| key.to_s.length }.max

    hash.map { |key, value|
      "#{key.to_s.rjust(max_key_length)}: #{value}"
    }.join("\n")
  end
end
