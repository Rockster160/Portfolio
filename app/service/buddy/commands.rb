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

    # The keys this person's tasks call, as the code spells them.
    def keys(user)
      codes = user.tasks.active.enabled.where("code LIKE ?", "%Buddy.command(%").pluck(:code)
      codes.flat_map { |code| code.to_s.scan(KEY_RX).flatten.map(&:strip) }.uniq(&:downcase).sort_by(&:downcase)
    end

    # The key they meant: in any case, or the same words in any order.
    def key(user, said)
      wanted = said.to_s.downcase.scan(/[a-z0-9]+/).sort
      keys(user).find { |key| key.downcase.scan(/[a-z0-9]+/).sort == wanted }
    end

    def items(user, key)
      Array(user.caches.dig(CACHE_KEY, key)).map { |item| item.to_h.deep_stringify_keys }
    end

    def save!(user, key, list)
      user.caches.dig_set(CACHE_KEY, key, list.presence)
    end

    def phrase(item)
      return "ask Buddy: \"#{item.dig("payload", "text")}\"" if item["tool_name"] == ASK

      BuddyRoutine.step_phrase(item)
    end

    # Each key and what it does now, after the tool's summary.
    def roster(user)
      keys(user).map { |key|
        list = items(user, key)
        "#{key} (#{list.any? ? list.map { |item| phrase(item) }.join(", ") : "nothing yet"})"
      }
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
