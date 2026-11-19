module Buddy
  # Keys a Jil task leaves for Buddy to fill, and running whatever fills them.
  #
  # A task declares one by calling `Buddy.command("Bathroom Button")`, and the
  # items saved for it live in the owner's cache under `buddy_commands`, where
  # the Jil cache page can show and edit them. Each item is a tool call in the
  # routine shape, `{ tool_name:, payload: }`, and `ask_buddy` is the one item
  # that isn't a tool: its `text` goes back to Buddy as a fresh request.
  module Commands
    module_function

    CACHE_KEY = :buddy_commands
    ASK = "ask_buddy".freeze

    # A literal key: `Buddy.command("Top Button")`. A key built at run time
    # can't be found by reading the code, so it can't be offered either.
    KEY_RX = /Buddy\.command\(\s*"([^"]+)"/

    # A press's state in the `hass` cache: "single", or "hold-3" for the third
    # button on a remote. Every press is recorded there by its device's name.
    PRESS_RX = /\A(?:single|double|hold)(?:-\d+)?\z/
    PRESSES = %i[single double hold].freeze

    # Each task that calls a key, as [key, listener], keys as the code spells
    # them.
    def slots(user)
      tasks = user.tasks.active.enabled.where("code LIKE ?", "%Buddy.command(%")
      tasks.pluck(:code, :listener).flat_map { |code, listener|
        code.to_s.scan(KEY_RX).flatten.map { |key| [key.strip, listener.to_s] }
      }.uniq { |key, _| key.downcase }.sort_by { |key, _| key.downcase }
    end

    # The keys this person's tasks call, as the code spells them.
    def keys(user)
      slots(user).map(&:first)
    end

    # The key a task on this listener already calls, so a second "program
    # button 9" fills the first one's key instead of making another task.
    def key_on(user, listener)
      slots(user).find { |_, on| on == listener }&.first
    end

    # Every button that has reported a press, by the name the house gives it.
    # A task can record its own press under its key, and those aren't devices.
    def buttons(user)
      taken = keys(user).map(&:downcase)
      presses = user.caches.get(:hass).to_h.select { |_, entry|
        entry.is_a?(Hash) && entry.with_indifferent_access[:state].to_s.match?(PRESS_RX)
      }
      presses.keys.map(&:to_s).reject { |name| taken.include?(name.downcase) }.sort_by(&:downcase)
    end

    # The button they meant: "button 9" is "Btn#9", in any case or order.
    def button(user, said)
      wanted = words(said)
      buttons(user).find { |name| words(name) == wanted }
    end

    def words(text)
      text.to_s.downcase.scan(/[a-z0-9]+/).map { |word| word == "btn" ? "button" : word }.sort
    end

    # The Jil listener for what should run a new key: a button's press, words
    # said to Jarvis, or a listener written out. Nil when none was given.
    def listener_for(user, button: nil, press: nil, phrase: nil, listener: nil)
      return button_listener(user, button, press) if button.present?
      return phrase_listener(phrase) if phrase.present?
      return if listener.blank?

      listener = listener.to_s.squish
      if Jil::ListenerMatch.scope_of(listener).blank? || listener.match?(/\Afunction\(/i)
        raise "#{listener.inspect} isn't a listener"
      end

      listener
    end

    def button_listener(user, said, press)
      name = button(user, said)
      if name.nil?
        known = buttons(user)
        heard = known.any? ? "the ones that have are #{known.to_sentence}" : "none have yet"
        raise "no button called #{said.to_s.inspect} has been pressed - #{heard}. A new " \
              "button shows up here once it's pressed"
      end
      if press.present? && PRESSES.exclude?(press.to_s.downcase.to_sym)
        raise "press has to be single, double or hold"
      end

      type = " type::#{press.to_s.downcase}" if press.present?
      %(hass-button:device_name::"#{name}"#{type})
    end

    def phrase_listener(phrase)
      words = phrase.to_s.downcase.scan(/[a-z0-9']+/)
      raise "a phrase needs words in it" if words.empty?

      "tell:/^#{words.join("\\s+")}[.!?]?$/"
    end

    # Makes the Jil task that runs `key` whenever `listener` fires. It's an
    # ordinary task, so it can be found and changed on the Jil page.
    def create!(user, key, listener)
      return if key_on(user, listener)

      user.tasks.create!(
        name:     key,
        listener: listener,
        enabled:  true,
        code:     %(ran = Buddy.command("#{key}")::Boolean),
      )
    end

    # How a key gets run, for the roster: "pressing Btn#4".
    def trigger_phrase(listener)
      if (device = listener[/\Ahass-button:device_name::"([^"]+)"/, 1])
        press = listener[/type::(\w+)/, 1]
        return [press, "pressing #{device}"].compact.join(" ")
      end
      words = listener[%r{\Atell:/\^(.+?)\[\.!\?\]\?\$/\z}, 1]
      %(saying "#{words.gsub("\\s+", " ")}") if words
    end

    # The key they meant: in any case, or the same words in any order.
    def key(user, said)
      wanted = words(said)
      keys(user).find { |key| words(key) == wanted }
    end

    def items(user, key)
      Array(user.caches.dig(CACHE_KEY, key)).map { |item| item.to_h.deep_stringify_keys }
    end

    def save!(user, key, list)
      user.caches.dig_set(CACHE_KEY, key, list.presence)
    end

    # The step's own phrase, then every argument it carries. The phrase names
    # one argument at most, and a key is changed by saving it whole again, so a
    # save rebuilt from the phrase alone loses whatever it left out.
    def phrase(item)
      return "ask Buddy: \"#{item.dig("payload", "text")}\"" if item["tool_name"] == ASK

      args = (item["payload"] || {}).to_h
      named = BuddyRoutine::PHRASE_ARGS.find { |arg| args[arg].present? }
      rest = args.except(named, Buddy::Tools::COUNT_ARG.to_s).filter_map { |arg, value|
        "#{arg}: #{value.is_a?(String) ? value : value.to_json}" unless value.nil? || value == ""
      }
      [BuddyRoutine.step_phrase(item), ("(#{rest.join(", ")})" if rest.any?)].compact.join(" ")
    end

    # Each key and what it does now, after the tool's summary, then each button
    # with nothing on it.
    def roster(user)
      taken = slots(user)
      rows = taken.map { |key, listener|
        list = items(user, key)
        does = list.any? ? list.map { |item| phrase(item) }.join(", ") : "nothing yet"
        "#{key} (#{[trigger_phrase(listener), does].compact.join(": ")})"
      }
      bound = taken.filter_map { |_, listener| listener[/device_name::"([^"]+)"/, 1]&.downcase }
      free = buttons(user).reject { |name| bound.include?(name.downcase) }
      rows + free.map { |name| "button #{name} (nothing on it yet)" }
    end

    # What Buddy is told when an `ask_buddy` item runs.
    ASK_SEED = "%<key>s just ran, and they set it to mean this: \"%<text>s\". Do that now, exactly " \
               "as if they had just asked you, and say briefly what you did.".freeze

    # False when nothing is saved under the key, or when the key is already
    # running further up: a step that fires the task holding it would
    # otherwise press it again from inside its own press.
    def run!(user, key)
      list = items(user, key)
      running = (Thread.current[:buddy_commands_running] ||= [])
      return false if list.empty? || running.include?(key)

      running << key
      mine = true
      asks, steps = list.partition { |item| item["tool_name"] == ASK }
      conversation = Buddy::CompanionRelay.conversation_for(user)
      if steps.any?
        markers = BuddyRoutine.new(steps: steps).markers
        Buddy::ProposalBuilder.run_markers!(user: user, conversation: conversation, markers: markers, body: nil)
      end
      asks.each { |item|
        Buddy::CompanionDelivery.deliver_prompt(
          user:         user,
          conversation: conversation,
          seed:         format(ASK_SEED, key: key, text: item.dig("payload", "text")),
          metadata:     { kind: :buddy_trigger, hidden: true, source: :jil_command },
        )
      }
      true
    ensure
      running.delete(key) if mine
    end
  end
end
