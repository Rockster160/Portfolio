class Jil::Validator
  Error = Struct.new(:line, :varname, :level, :message, keyword_init: true)

  attr_reader :errors, :warnings, :code, :lines

  def initialize(code, user_function_names: [])
    @code = code
    @user_function_names = user_function_names.map(&:to_s)
    @errors = []
    @warnings = []
    @vars = {} # varname => { cast: Symbol, line_num: Integer }
    @lines = []
  end

  def self.validate(code, **opts)
    new(code, **opts).tap(&:validate)
  end

  def self.validate!(code, **opts)
    result = validate(code, **opts)
    return result if result.valid?

    messages = result.errors.map { |e| "[#{e.varname}] #{e.message}" }.join("\n")
    raise ::Jil::ExecutionError, "Jil validation failed:\n#{messages}"
  end

  def valid?
    @errors.empty?
  end

  def validate
    parse_code
    @lines.each_with_index { |line, idx| validate_line(line, idx) }
    self
  end

  # --- Schema introspection (derived from schema.txt and executor) ---

  def self.schema_classes
    @schema_classes ||= parse_schema_classes
  end

  def self.data_classes
    @data_classes ||= parse_schema_classes(starred_only: true)
  end

  def self.valid_casts
    @valid_casts ||= schema_classes | Set[:Any, :None]
  end

  def self.valid_objnames
    @valid_objnames ||= schema_classes | Set[:Custom, :Keyword]
  end

  def self.keyword_noop_methods
    @keyword_noop_methods ||= begin
      source = File.read(Rails.root.join("app/service/jil/methods/keyword.rb"))
      methods = Set.new
      source.scan(/when :(\w+) then nil/).each { |m| methods << m[0].to_sym }
      methods
    end
  end

  # Parse schema to find methods that accept content(Keyval|Hash) or content(Keyval)
  # These legitimately take Keyval content blocks as args.
  def self.methods_accepting_keyval_content
    @methods_accepting_keyval_content ||= begin
      result = Set.new
      current_class = nil

      File.readlines(schema_path).each do |line|
        if (m = line.match(/^\*?\[(\w+)\]/))
          current_class = m[1].to_sym
          next
        end
        next unless current_class

        if (m = line.match(/^\s+[!]?[#.](\w+[!?]?)\((.+)\)/))
          method_name = m[1].to_sym
          args_str = m[2]
          if args_str.match?(/content\([^)]*Keyval[^)]*\)/i)
            result << [current_class, method_name]
          end
        end
      end
      result
    end
  end

  # Parse schema to find data class methods where data() takes a bare Hash (not content)
  def self.data_methods_expecting_content
    @data_methods_expecting_content ||= begin
      result = Set.new
      current_class = nil

      File.readlines(schema_path).each do |line|
        if (m = line.match(/^\*?\[(\w+)\]/))
          current_class = m[1].to_sym
          next
        end
        next unless current_class
        next unless data_classes.include?(current_class)

        if (m = line.match(/^\s+[!]?[#.]data\((.+)\)/))
          args_str = m[1]
          result << current_class if args_str.match?(/content\(/)
        end
      end
      result
    end
  end

  def self.schema_path
    Rails.root.join("app/service/jil/schema.txt")
  end

  # Returns { ClassSym => { class_methods: { method => [arg_types] }, instance_methods: { method => [arg_types] } } }
  def self.schema_methods
    @schema_methods ||= begin
      classes = {}
      current_class = nil
      File.readlines(schema_path).each do |line|
        if (m = line.match(/^\*?\[(\w+)\]/))
          current_class = m[1].to_sym
          classes[current_class] ||= { class_methods: {}, instance_methods: {} }
          next
        end
        next unless current_class

        m = line.match(/^\s+!?([#.])(\w+[!?]?)(?:\(((?:[^()]|\([^()]*\))*)\))?/)
        next unless m

        kind = m[1]
        method_name = m[2].to_sym
        args_str = m[3] || ""
        arg_types = parse_arg_types(args_str)

        bucket = kind == "#" ? :class_methods : :instance_methods
        classes[current_class][bucket][method_name] = arg_types
      end
      classes
    end
  end

  # Tokenize an arg list, dropping labels (bare quoted strings) and formatting tokens.
  # Returns array of arg type symbols/strings. Ex: 'Text:"Query" Numeric?(10000):"Limit"' -> [:Text, :Numeric]
  def self.parse_arg_types(args_str)
    return [] if args_str.blank?

    tokens = []
    current = +""
    depth = 0
    in_quote = false
    prev = nil

    args_str.each_char do |c|
      if in_quote
        current << c
        in_quote = false if c == "\"" && prev != "\\"
      elsif c == "\""
        in_quote = true
        current << c
      elsif "([".include?(c)
        depth += 1
        current << c
      elsif ")]".include?(c)
        depth -= 1
        current << c
      elsif c == " " && depth.zero?
        tokens << current.dup unless current.empty?
        current.clear
      else
        current << c
      end
      prev = c
    end
    tokens << current unless current.empty?

    formatting = Set[:TAB, :BR]
    tokens.reject { |t|
      t.match?(/\A"[^"]*"\z/) || formatting.include?(t.to_sym)
    }.map { |t|
      base = t.sub(/[?!]?(?:\([^)]*\))?(?::.*)?\z/, "")
      base.to_sym
    }
  end

  def self.parse_schema_classes(starred_only: false)
    classes = Set.new
    pattern = starred_only ? /^\*\[(\w+)\]/ : /^\*?\[(\w+)\]/
    File.readlines(schema_path).each do |line|
      match = line.match(pattern)
      classes << match[1].to_sym if match
    end
    classes
  end

  private

  def parse_code
    @lines = Jil::Parser.from_code(@code) || []
  rescue StandardError => e
    add_error(nil, nil, "Failed to parse Jil code: #{e.message}")
  end

  def validate_line(line, line_idx, parent_class: nil, parent_method: nil)
    return if line.commented?

    varname = line.varname
    objname = line.objname.to_sym
    methodname = line.methodname.to_sym
    cast = line.cast.to_sym

    validate_cast(line, cast)
    validate_varname(line, varname, cast)
    validate_objname(line, objname)
    validate_method_exists(line, objname, methodname)
    validate_arg_types(line, objname, methodname)
    validate_args(line, objname, methodname, parent_class, parent_method)
    validate_content_blocks(line, objname, methodname)

    @vars[varname.to_sym] = { cast: cast, line_num: line_idx }
  end

  # --- Individual validators ---

  def validate_cast(line, cast)
    return if self.class.valid_casts.include?(cast)

    add_error(line, line.varname, "Invalid cast type '#{cast}'")
  end

  def validate_varname(line, varname, cast)
    existing = @vars[varname.to_sym]
    return unless existing

    add_error(line, varname, "Variable '#{varname}' already defined (first used as ::#{existing[:cast]})")
  end

  def validate_objname(line, objname)
    if objname.to_s.match?(/\A[A-Z]/)
      return if self.class.valid_objnames.include?(objname)

      add_error(line, line.varname, "Unknown class '#{objname}'")
    else
      return if @vars.key?(objname)

      add_error(line, line.varname, "Variable '#{objname}' used before definition")
    end
  end

  # Classes whose methods are dynamic/wildcard — skip method existence check.
  WILDCARD_CLASSES = Set[:Custom, :Keyword, :Any, :None, :Global].freeze
  # Methods always available via Jil::Methods::Base, regardless of class.
  UNIVERSAL_METHODS = Set[:new, :inspect, :presence].freeze

  def validate_method_exists(line, objname, methodname)
    return if UNIVERSAL_METHODS.include?(methodname)

    if objname.to_s.match?(/\A[A-Z]/)
      return if WILDCARD_CLASSES.include?(objname)
      return unless self.class.schema_methods.key?(objname)

      class_methods = self.class.schema_methods.dig(objname, :class_methods) || {}
      instance_methods = self.class.schema_methods.dig(objname, :instance_methods) || {}

      return if class_methods.key?(methodname)

      if instance_methods.key?(methodname)
        add_error(line, line.varname,
          "Unable to call `#{methodname}` on `#{objname}` as a class method. " \
          "`#{methodname}` is an instance method — call it on a variable: `var.#{methodname}(...)`.")
      else
        add_error(line, line.varname, "Unable to call `#{methodname}` on `#{objname}`")
      end
    else
      var_class = @vars.dig(objname.to_sym, :cast)
      return unless var_class

      # The in-browser Jil editor can't validate instance method calls on
      # `::Any` variables (Any has no schema to dispatch against) — on save
      # it silently strips the call's args AND discards every line that
      # follows. We hit this on slime-colony Setup (task 372 in prod): a
      # `Global.if(...)::Any` result fed into `ap.op("+", 1)` chopped
      # ~4500 chars off the task. Reject these here so the issue surfaces
      # before deploy. Cast the source line to a concrete type instead —
      # e.g. `var = Global.if(...)::Numeric`.
      if var_class == :Any
        add_error(line, line.varname,
          "Cannot call instance method `#{methodname}` on `::Any` variable `#{objname}`. " \
          "The in-browser Jil editor silently strips args from `::Any` method calls and " \
          "discards everything that follows on save. Cast the source line to a concrete " \
          "type — e.g. `#{objname} = SomeFn(...)::<Type>` — so the editor can validate " \
          "the call.")
        return
      end

      return if WILDCARD_CLASSES.include?(var_class)
      return unless self.class.schema_methods.key?(var_class)

      instance_methods = self.class.schema_methods.dig(var_class, :instance_methods) || {}
      class_methods = self.class.schema_methods.dig(var_class, :class_methods) || {}

      return if instance_methods.key?(methodname)

      if class_methods.key?(methodname)
        add_error(line, line.varname,
          "Unable to call `#{methodname}` on `::#{var_class}` instance. " \
          "`#{methodname}` is a class method — call it as `#{var_class}.#{methodname}(...)`.")
      else
        add_error(line, line.varname, "Unable to call `#{methodname}` on `::#{var_class}`")
      end
    end
  end

  def validate_arg_types(line, objname, methodname)
    arg_types = lookup_arg_types(objname, methodname)
    return if arg_types.nil?

    line.args.each_with_index do |arg, idx|
      expected = arg_types[idx]
      next if expected.nil?
      next unless expected == :Text

      next if arg.is_a?(::String) && arg.match?(/\A".*"\z/m)

      add_error(line, line.varname,
        "Arg #{idx + 1} of `#{objname}.#{methodname}` is `Text` — must be a literal string `\"...\"`, " \
        "not a variable reference. (#{objname == :String ? "Use" : "Build the string with"} `String.new(\"...\")` " \
        "to interpolate variables.)")
    end
  end

  def lookup_arg_types(objname, methodname)
    if objname.to_s.match?(/\A[A-Z]/)
      return nil if WILDCARD_CLASSES.include?(objname)
      return nil unless self.class.schema_methods.key?(objname)

      self.class.schema_methods.dig(objname, :class_methods, methodname)
    else
      var_class = @vars.dig(objname.to_sym, :cast)
      return nil unless var_class
      return nil if WILDCARD_CLASSES.include?(var_class)

      self.class.schema_methods.dig(var_class, :instance_methods, methodname)
    end
  end

  def validate_args(line, objname, methodname, parent_class, parent_method)
    args = line.args

    validate_no_raw_keyval_blocks(line, objname, methodname, args)
    validate_content_not_bare_variable(line, objname, methodname, args)
    validate_keyword_usage(line, objname, methodname, parent_class, parent_method)
  end

  def validate_no_raw_keyval_blocks(line, objname, methodname, args)
    # Multi-line Keyval content blocks are valid in Hash.new and methods that
    # declare content(Keyval|Hash) in the schema or in user function listeners
    return if objname == :Hash && methodname == :new
    return if self.class.methods_accepting_keyval_content.include?([objname, methodname])
    return if objname == :Custom && custom_function_accepts_keyval_content?(methodname)
    return if args.length <= 1

    args.each_with_index do |arg, idx|
      next unless arg.is_a?(::Array) && arg.length > 1
      next unless arg.all? { |a| a.is_a?(::Jil::Parser) && a.objname.to_sym == :Keyval }

      add_error(line, line.varname,
        "Arg #{idx + 1}: Raw Keyval content block passed as positional argument. " \
        "Use Hash.new({...}) to create a Hash variable first, then pass the variable.")
    end
  end

  def validate_content_not_bare_variable(line, objname, methodname, args)
    # Only warn for data classes whose data() method uses content() in schema
    return unless methodname == :data
    return unless self.class.data_methods_expecting_content.include?(objname)
    return if args.empty?

    first_arg = args.first
    if first_arg.is_a?(::String) && !first_arg.match?(/\A".*?"\z/)
      add_warning(line, line.varname,
        "#{objname}.data() expects a content block {}, not a bare variable. " \
        "Use #{objname}.data({ Global.ref(#{first_arg})::Hash }) instead.")
    end
  end

  KEYWORD_VALID_PARENTS = {
    Item: [:functionParams, :splat],
    NamedArg: [:functionParams, :function],
    When: [:case],
    Else: [:case],
  }.freeze

  def validate_keyword_usage(line, objname, methodname, parent_class, parent_method)
    return unless objname == :Keyword
    return unless self.class.keyword_noop_methods.include?(methodname)

    # Check if this keyword is in a valid parent context
    valid_parents = KEYWORD_VALID_PARENTS[methodname]
    return if valid_parents&.include?(parent_method)

    add_warning(line, line.varname,
      "Keyword.#{methodname}() is a no-op in most contexts. " \
      "In enumerations, use Keyword.Object() for the current element.")
  end

  def validate_content_blocks(line, objname, methodname)
    line.args.each do |arg|
      next unless arg.is_a?(::Array)

      arg.each_with_index do |nested_line, idx|
        next unless nested_line.is_a?(::Jil::Parser)

        validate_line(nested_line, idx, parent_class: objname, parent_method: methodname)
      end
    end
  end

  def custom_function_accepts_keyval_content?(method_name)
    # Check if a Custom function's listener declares content(Keyval|Hash) or content(Hash|Keyval)
    @custom_function_listeners ||= begin
      tasks = User.me.tasks.active.enabled.functions
      tasks.each_with_object({}) { |t, h|
        # Normalize name the same way by_method_name does
        normalized = t.name.gsub(/\W+/, "").gsub(" ", "_")
        h[normalized] = t.listener
      }
    rescue StandardError
      {}
    end

    listener = @custom_function_listeners[method_name.to_s]
    return false unless listener

    listener.match?(/content\([^)]*(?:Keyval|Hash)[^)]*\)/i)
  end

  # --- Helpers ---

  def add_error(line, varname, message)
    @errors << Error.new(line: line, varname: varname, level: :error, message: message)
  end

  def add_warning(line, varname, message)
    @warnings << Error.new(line: line, varname: varname, level: :warning, message: message)
  end
end
