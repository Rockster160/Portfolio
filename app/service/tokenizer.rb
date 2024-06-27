# tz = Tokenizer.new(str)
# tz.tokenize!(str, /\".*?\"/m)
# # Make other changes to `str`
# tz.untokenize!(str)

class Tokenizer
  attr_accessor :stored_strings, :token

  def self.protect(str, *rxs, &block)
    return str if str.blank?
    str = str.dup
    tz = new(str)
    rxs.each { |rx| tz.tokenize!(str, rx) }
    tz.untokenize!(block.call(str))
  end

  def self.split(str, *rxs, by: " ", unwrap: false)
    return str if str.blank?
    str = str.dup
    tz = new(str)
    rxs.each { |rx| tz.tokenize!(str, rx) }
    str.split(by).map { |sub_str|
      tz.untokenize(sub_str).then { |wrapped_str|
        next wrapped_str unless unwrap
        rxs.lazy.map { |rx| wrapped_str[rx, 1] }.find(&:itself) || wrapped_str
      }
    }
  end

  def self.wrap_regex(open_str, close_str=nil)
    close_str ||= open_str
    /(?<!\\)#{Regexp.escape(open_str)}(.*?)(?<!\\)#{Regexp.escape(close_str)}/
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
    loop do
      start = full.dup
      @stored_strings.each_with_index do |stored, idx|
        full.gsub!("#{@token}..#{idx}..", stored)
      end
      break if start == full
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
    loop do
      start = full.dup
      @stored_strings.each_with_index do |stored, idx|
        full = full.gsub("#{@token}..#{idx}..", stored)
      end
      break if start == full
    end
    full
  end
end
