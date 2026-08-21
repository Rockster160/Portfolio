module Buddy
  # GPT is down for the whole house.
  #
  # Distinct from Buddy::SleepGuard's usage-cap sleep, and deliberately behaving
  # differently. A usage cap has a RESET TIME, so the honest thing is to hold
  # what you send and deliver it when the window passes — which is what
  # `sleep_until!` does. An outage has no known end, so holding is a promise
  # nobody can keep: the messages sit in a queue that may never drain, and the
  # person believes they were sent. So here the message FAILS, says so, and
  # offers a retry.
  #
  # House-wide because it is one API key. The alternative is Eve and Chelsea
  # each discovering it by sending something and watching it die.
  #
  # Nothing clears it on a timer, on purpose. It comes back when a real call
  # succeeds — either the retry link in the Slack post, or a person tapping
  # retry on their own failed message.
  module Outage
    module_function

    CACHE_KEY = :buddy_gpt_outage

    # Far enough out that no wake sweep will trip it, and recognisable in the
    # database as "not a real time" if anyone goes looking.
    FOREVER = 100.years

    REASON = "gpt_outage".freeze

    def down?
      state[:down] == true
    end

    def since
      ts = state[:down_at]
      ts.present? ? Time.zone.at(ts.to_i) : nil
    end

    def detail
      state[:detail].presence
    end

    # Record it, put every companion in the house to sleep, and say so in Slack
    # with the way out attached. Idempotent: a second failure while already down
    # neither re-sleeps nor re-posts, or one outage would fill the channel at
    # the rate people keep typing.
    def down!(detail: nil)
      return state if down?

      write(down: true, down_at: Time.current.to_i, detail: detail.to_s.presence)
      household_users.each { |user| Buddy::SleepGuard.sleep_indefinitely!(user, reason: REASON) }
      announce!(detail)
      state
    end

    # Wake the house. Safe to call when already awake.
    def clear!
      household_users.each { |user| Buddy::SleepGuard.wake!(user) if Buddy::SleepGuard.reason(user) == REASON }
      write(down: false, down_at: nil, detail: nil)
    end

    # The way back. Spends one real, tiny call rather than trusting that enough
    # time has passed — the whole failure mode being fixed is a companion that
    # says it is fine when it isn't.
    def retry!
      return "Buddy wasn't asleep — nothing to retry." unless down?

      result = Buddy::GPT::Client.new.ping
      if result[:ok]
        clear!
        "Back up. Everyone's awake."
      else
        write(detail: result[:error].to_s.presence)
        "Still down: #{result[:error]}"
      end
    end

    # Everyone whose companions run on this key. Falls back to the owner alone
    # if there is no household, because a house of one is still a house.
    def household_users
      household = User.me.chore_household
      return [User.me] if household.nil?

      household.members.to_a.presence || [User.me]
    end

    def announce!(detail)
      SlackNotifier.notify(<<~MSG)
        :sleeping: *Buddy is asleep — GPT is down*
        #{detail.presence || "no detail"}
        Every companion is sleeping and messages are failing until this clears.
        #{Slack::Actions.link(:buddy_retry)}
      MSG
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Outage] announce failed: #{e.class}: #{e.message}")
    end

    def state
      (User.me.caches.get(CACHE_KEY) || {}).symbolize_keys
    end

    def write(patch)
      merged = state.merge(patch.symbolize_keys)
      User.me.caches.set(CACHE_KEY, merged.stringify_keys)
      merged
    end
  end
end
