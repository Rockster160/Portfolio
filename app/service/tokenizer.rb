# tz = Tokenizer.new(str)
# tz.tokenize!(str, /\".*?\"/m)
# # Make other changes to `str`
# tz.untokenize!(str)

class Tokenizer
  attr_accessor :stored_strings, :token

  def self.protect(str, *rxs, &block)
    str = str.dup
    tz = new(str)
    rxs.each { |rx| tz.tokenize!(str, rx) }
    tz.untokenize!(block.call(str))
  end

  def initialize(full_str)
    @unwrap = nil
    @stored_strings = []
    @token = loop {
      hex = SecureRandom.hex
      break hex unless full_str.include?(hex)
    }
  end

  def tokenize!(full, regex)
    full.gsub!(regex) do |found|
      @stored_strings << found
      "#{@token}..#{@stored_strings.length-1}.."
    end
  end

  def untokenize!(full)
    @stored_strings.each_with_index do |stored, idx|
      full.gsub!("#{@token}..#{idx}..", stored)
    end
    full
  end

  def tokenize(full, regex)
    full.gsub(regex) do |found|
      @stored_strings << found
      "#{@token}..#{@stored_strings.length-1}.."
    end
  end

  def untokenize(full)
    @stored_strings.each_with_index do |stored, idx|
      full = full.gsub("#{@token}..#{idx}..", stored)
    end
    full
  end
end
