module ScheduleCondition
  # The `device` kind: what a Home Assistant device last reported, off the
  # state cache Buddy::DeviceStates reads, compared with the state the rule
  # names.
  module Device
    module_function

    # Sensors report a verb's bare form ("close", "open") where people say the
    # adjective, so both spellings of a state count as the same state.
    STATE_ALIASES = {
      "closed"   => "close",
      "opened"   => "open",
      "shut"     => "close",
      "locked"   => "lock",
      "unlocked" => "unlock",
    }.freeze

    def normalize(data)
      raise "a device condition needs the device's name" if data[:device].blank?
      raise "a device condition needs the state to compare with (\"open\", \"on\")" if data[:state].blank?

      { device: data[:device].to_s.strip, state: data[:state].to_s.strip.downcase }
    end

    # The last thing the device said, however long ago. Sensors report on a
    # CHANGE, so a garage that closed six hours ago and hasn't moved since is
    # closed - staleness is a reason to word an answer carefully, never a
    # reason to say the state is unknown.
    def state(name, user)
      row = ::Buddy::DeviceStates.find(user, name)
      raise "no device called #{name.inspect} reports in" if row.nil?
      raise "#{row[:device]} hasn't reported a state" if row[:state].blank?

      row[:state]
    end

    def same?(actual, wanted)
      canon(actual) == canon(wanted)
    end

    def canon(state)
      word = state.to_s.downcase.strip
      STATE_ALIASES.fetch(word, word)
    end
  end
end
