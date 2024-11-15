# DEPRECATED! Use Tokenizing::Node instead
module SearchParser
  module_function

  def call(str, delimiters={})
    aliases = delimiters.delete(:aliases)
    str = str.dup
    tr = OldTokenizer.new(str)

    delims_with_aliases = delimiters.to_a.each_with_object([]) { |(dk, d), obj|
      obj << [dk, d]
      aliases&.each do |old_a, new_a|
        obj << [dk, d.gsub(old_a.to_s, new_a.to_s)] if d.include?(old_a.to_s)
      end
    }.uniq
    sorted_delims = delims_with_aliases.sort_by { |dk, d| -d.length }
    tokenized_split(str, tr).each_with_object({}) { |piece, obj|
      next if sorted_delims.find do |delim_key, delim|
        next unless piece.include?(delim)
        key, val = piece.split(delim, 2).map { |piece|
          case tr.untokenize!(piece)
          when /^".*?"$/ then piece[1..-2]
          when /\(.*?\)/
            tokenized_split(piece[1..-2]).map { |piece| SearchParser.call(piece, delimiters) }
          else piece
          end
        }

        obj[:props] ||= {}
        delim_obj = obj[:props][delim_key] ||= {}

        if key.blank?
          delim_obj[:terms] ||= []
          delim_obj[:terms] << val
        else
          delim_obj[:props] ||= {}
          delim_obj[:props][key.to_sym] ||= []
          delim_obj[:props][key.to_sym] << val
        end
      end
      # Missed all delims, so put into the default
      obj[:terms] ||= []
      obj[:terms] << (piece.match?(/^".*?"$/) ? piece[1..-2] : piece)
    }
  end

  def tokenized_split(str, tr=nil)
    str = str.dup
    rebuild = !tr.nil?
    tr ||= OldTokenizer.new(str)
    tr.tokenize!(str, /\\./)
    tr.tokenize!(str, /".*?"/)
    tr.tokenize!(str, /\(.*?\)/)

    return str.split(/\s/) unless rebuild

    str.split(/\s/).map { |piece| tr.untokenize!(piece) }
  end
end

# reload!; ActionEvent.query('name:thing has:"bigger string" search each ~sorta word !bad notes!:z name::thing or:(includes:dog includes:cat)')
# reload!; SearchParser.call(
# 'name:thing has:"bigger string" search each ~sorta word !bad notes!:z name::thing or:(includes:dog includes:cat)'
# )
# 'name:thing has:"bigger string" search each ~sorta word !bad notes!:z name::thing or:(includes:dog includes:cat)'
# {
#   name: [
#     "thing"
#   ],
#   has: [
#     "bigger string"
#   ],
#   words: [
#     "search",
#     "each",
#     "word"
#   ],
#   "!": [
#     "bad"
#   ],
#   or: [
#     {
#       includes: [
#         "dog",
#         "cat"
#       ]
#     }
#   ]
# }
