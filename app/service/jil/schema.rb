class Jil::Schema
  # Who is allowed to SEE each part of the Jil vocabulary.
  #
  # `Task.schema` feeds the editor everything it knows — every class, every
  # method, every autocomplete entry — and it used to hand the same text to
  # everyone. The owner-only classes were in there for the whole household, so
  # a non-owner's editor offered them `Tesla.unlockDoors` and `Mac.run`, with
  # the only thing between the offer and the car being a guard at execution time
  # telling them no. Refusing is right; offering it first is a menu of things that
  # cannot work.
  #
  # A gate is an `@name` suffix on the line it applies to. On a class header it
  # takes the whole block; on a method line it takes that one method:
  #
  #   [Tesla]@me
  #     #start(content(TeslaStartOptions))::Boolean
  #
  #   [Global]
  #     #someAdminThing(String)::Any @admin
  #
  # No method-level gate is in use yet — every restriction in the language today
  # is the whole class — but the language costs nothing to support and the
  # alternative is inventing it under pressure later.
  #
  # This is the MENU, not the lock. Enforcement stays with the method
  # (`Jil::Methods::Mac#permitted?`, `Jil::Methods::Tesla#wrap`), because code
  # reaches the executor by routes that never open the editor: a shared task, a
  # trigger, `devExec`, a prodExec script. Hiding a class here does not stop
  # any of those, and is not meant to.
  GATES = {
    me:    ->(user) { user&.me? },
    admin: ->(user) { user&.admin? },
  }.freeze

  PATH = Rails.root.join("app/service/jil/schema.txt")

  CLASS_LINE = /\A\*?\[(\w+)\]/
  # Deliberately tight: `@` followed by a word, immediately after the class
  # bracket or the method signature. Nothing else in schema.txt contains an `@`.
  GATE = /@(\w+)/

  # `keep:` names classes to pass through whatever the gates say. The editor
  # renders a task's existing code against this schema, and `Schema.method` in
  # jil/schema.js dereferences `types[name]` without a guard — so stripping a
  # class that the task ON SCREEN uses throws before the page draws. A shared
  # task opens read-only for the person it's shared with (Jil::TasksController
  # #show), and that person is exactly who fails the gate. They are already
  # looking at the code; keeping the class it names is what lets them see it.
  def self.for(user, keep: [])
    new(user, keep: keep).text
  end

  def initialize(user, keep: [])
    @user = user
    @keep = Array.wrap(keep).to_set(&:to_s)
  end

  def text
    in_visible_class = true

    File.readlines(PATH).map { |line| fill(line) }.filter_map { |line|
      classname = line[CLASS_LINE, 1]

      if classname.present?
        in_visible_class = @keep.include?(classname) || permitted?(line)
        next unless in_visible_class
      else
        next unless in_visible_class
        next unless permitted?(line)
      end

      strip_gate(line)
    }.join
  end

  private

  # Dropdowns whose choices depend on who is looking: `%WHO%` is who a Buddy
  # alert can be for - themselves, everyone, or a household member by name -
  # and `%SYSTEM_FACES%` the faces every pet can wear (the `*` beside it lets
  # any other face name be typed).
  def fill(line)
    return line unless line.include?("%")

    line.gsub("%WHO%") { quoted(who_choices) }.gsub("%SYSTEM_FACES%") { quoted(Buddy::Faces.system_faces) }
  end

  def who_choices
    house = @user&.chore_household
    names = house ? house.members.order(:id).map(&:first_name) : []
    ["me", "everyone", *names]
  end

  def quoted(names)
    names.map { |name| "\"#{name}\"" }.join(" ")
  end

  # An unrecognized gate name fails CLOSED, so a typo hides a class from
  # everyone rather than quietly showing a restricted one to the household.
  def permitted?(line)
    gate = line[GATE, 1]
    return true if gate.nil?

    GATES.fetch(gate.to_sym) { ->(_user) { false } }.call(@user)
  end

  def strip_gate(line)
    line.sub(GATE, "")
  end
end
