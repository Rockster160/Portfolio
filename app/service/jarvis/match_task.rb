# Jarvis - Trigger Jil tasks - able to add dynamic words
#   * Common words will be filtered out of task names and inputs
#   * (opt) will be optional text (no group)
#   * (this|that|other) will be optional text and match any of the givens (no group)
#   * (:/regexp/) optional that matches regex
#   * (!opt) is required text (no group) - mostly only used when multiple options are provided:
#   * (!this|that|other) will require any of the givens (no group)
#   * {var} will lazy match everything by default. Can provide a regexp to be more specific - accessed through `var` variable within function

#   * "How far is {address:/regexp/}" - sets "address" as input variable
#   * "Take me to {address:/regexp/}" - sets "address" as input variable
#   * "Set the house to {temp:/\d+/} (degrees)" - sets "address" as input variable

module Jarvis::MatchTask
  module_function

  COMMON_WORDS = [:to, :my, :it, :I, :you, :the, :at, :on, :is, :me, :us, :we]

  def match_run(user, ostr, skip=[])
    task = find_match(user, ostr, skip)
    return unless task.present?

    # TODO- Do NOT replace common words that are inside () and {}
    simple_str = ostr.gsub(rx.words(*COMMON_WORDS), "").downcase.squish # Filter out special chars? Like () {} []...
    simple_name = task.name.gsub(rx.words(*COMMON_WORDS), "").downcase.squish
    simple_name.gsub!(/(\{.*?\})|(\(.*?\))/) { |found|
      optional = found.squish.first == "("
      match_data = found.match(/\{(?<name>\w+)(?::?\s*(?<regex>\/.*?\/))?(?<word>.*?)?\s*\}/)
      match_data ||= found.match(/\((?<name>)(?::?\s*(?<regex>\/.*?\/))?(?<word>.*?)?\s*\)/)
      match = match_data[:regex].to_s[1..-2].presence
      match ||= match_data[:word].presence
      match ||= ".*?"
      if match[0] == "!"
        optional = false
        match[0] = ""
      end
      "(#{"?<#{match_data[:name]}>" if match_data[:name].present?}#{match.gsub("\\", "\\\\")})#{"?" if optional}"
    }.gsub!(/ *(\([^\)]*?\)\?)/, ' ?\1')
    md = simple_str.match(Regexp.new(simple_name))

    return match_run(user, ostr, skip + [task.id]) if md.blank?


    ::Jarvis::Execute.call(task, vars: md.named_captures).then { |res|
      res = Array.wrap(res).select { |item| item.present? && item != "Success" }
      res.first || Jarvis::Text.affirmative
    }
  end

  def find_match(user, ostr, skip=[])
    # BIG TODO!
    # SANTIZE `str` - it is user input and can be executed against the db
    str = ostr.gsub(rx.words(*COMMON_WORDS), "").downcase.squish # Filter out special chars? Like () {} []...

    name_regex = replaces(
      "\\m(#{COMMON_WORDS.join("|")})\\M" => "",
      " *\\(.*\\) *" => "%", # This should probably verify to only apply if the nested regex matches
      " *\\{.*\\} *" => "%", # This should probably verify to only apply if the nested regex matches
      " {2,}" => " ",
      "\\% *\\%" => "%",
    )

    # task_name = JarvisTask.first.name
    # regex = name_regex.gsub("REGEXP_REPLACE(name", "REGEXP_REPLACE('#{task_name}'")
    # puts "\e[36m<< '#{ostr}'\e[0m"
    # puts "\e[36m>> '#{exe_rx(regex)}'\e[0m"
    # puts "\e[36m?r '#{str}' ~~* '#{exe_rx(regex)}'\e[0m"
    # puts "\e[36m?r #{exe_bool("'#{str}' ~~* '#{exe_rx(regex)}'").then { |b| "\e[3#{b ? 2 : 1}m#{b}" }}\e[0m"
    #
    # puts "\e[36m?a #{exe_bool("'#{str}' ~~* #{regex}").then { |b| "\e[3#{b ? 2 : 1}m#{b}" }}\e[0m"
    # puts "\e[36m?a #{exe_bool("'#{str}' ~~* '#{exe_rx(regex)}'").then { |b| "\e[3#{b ? 2 : 1}m#{b}" }}\e[0m"
    user.jarvis_tasks.tell.where.not(id: skip).find_by("'#{str}' ~~* #{name_regex}")
  end

  def exe_rx(st)
    # puts "\e[33m[LOGIT][RX] | SELECT #{st};\e[0m"
    ActiveRecord::Base.connection.execute("SELECT #{st};").to_a.first.values.first
  end

  def exe_bool(st)
    # puts "\e[33m[LOGIT][BOOL] | SELECT (#{st})::boolean;\e[0m"
    ActiveRecord::Base.connection.execute("SELECT (#{st})::boolean;").to_a.first.values.first
  end

  def rx
    @rx ||= Jarvis::Regex
  end

  def replaces(hash)
    nest = "name"
    hash.map.each do |k, v|
      nest = "REGEXP_REPLACE(#{nest}, \'#{k}\', \'#{v}\', \'ig\')"
    end
    nest
  end
end
