module Buddy
  # What's on its way to the house.
  #
  # AmazonOrder is the store and none of it is new: a list rebuilt from shipping
  # emails (Amazon, and UPS / USPS / FedEx through their own parsers) plus rows
  # added by hand from the dashboard. This is the reading and writing of it that
  # Buddy needs, in the shapes a tool wants.
  #
  # It lives under MeCache, which is the OWNER's cache and nobody else's. There
  # is no per-user delivery list to fall back to, so `available?` is checked on
  # every call rather than leaning on the feature gate alone — a feature granted
  # by mistake would otherwise point somebody else's companion at his packages.
  module Deliveries
    module_function

    DEFAULT_DAYS = 14
    MAX_DAYS     = 120
    LIMIT        = 20

    # A delivered row is history the moment it lands, and the list is mostly
    # read to answer "what's coming". They're kept for a few days so "did the
    # desk ever turn up" still has an answer.
    KEEP_DELIVERED_DAYS = 5

    def available?(user)
      user.respond_to?(:me?) && user.me?
    end

    # Fresh from the cache every time. AmazonOrder memoizes into a class
    # variable, and Buddy runs inside long-lived Sidekiq processes — without
    # this a worker answers from whatever the list looked like when it booted.
    def orders
      AmazonOrder.reload
      AmazonOrder.ordered
    end

    def call(user:, query: nil, days: DEFAULT_DAYS, limit: LIMIT)
      return { rows: [], count: 0 } unless available?(user)

      window = days.to_i.clamp(1, MAX_DAYS)
      found  = narrow(within(orders, window, user), query)

      { rows: found.first(limit).map { |o| row(o, user) }, count: found.length }
    end

    # Upcoming inside the window, plus anything overdue (a date that's been and
    # gone with no delivery confirmation is exactly what someone is asking about)
    # and the last few days of arrivals.
    def within(all, days, user)
      today = user.perceived_today
      all.select { |order|
        date = delivery_date(order)
        next true if date.nil? # no date at all is still something they ordered

        if order.delivered
          date >= today - KEEP_DELIVERED_DAYS
        else
          date <= today + days
        end
      }
    end

    def narrow(all, query)
      words = folded(query).split.reject { |w| w.length < 2 }
      return all if words.empty?

      hit = all.select { |o| words.all? { |w| folded(searchable(o)).include?(w) } }
      return hit if hit.any?

      all.select { |o| words.any? { |w| folded(searchable(o)).include?(w) } }
    end

    def searchable(order)
      [order.name, order.listed_name, order.full_name, order.carrier, order.tracking_number].join(" ")
    end

    def folded(text)
      text.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def row(order, user)
      [
        display_name(order),
        when_phrase(order, user),
        carrier_phrase(order),
        (format("$%.2f", order.amount) if order.amount.to_f.positive?),
      ].compact.join(" · ")
    end

    def display_name(order)
      order.name.presence || order.listed_name.presence || order.full_name.presence || "unnamed item"
    end

    # A date that's passed means different things depending on whether it
    # arrived: "arrived Monday" is an answer, and "was due Monday" is a problem.
    def when_phrase(order, user)
      date = delivery_date(order)
      return "no date on it" if date.nil?

      today = user.perceived_today
      day   = friendly(date, today)
      return "arrived #{day}" if order.delivered
      return "was due #{day}" if date < today

      window = order.time_range.to_s.strip.presence
      ["due #{day}", window].compact.join(", ")
    end

    def friendly(date, today)
      return "today" if date == today
      return "tomorrow" if date == today + 1
      return "yesterday" if date == today - 1

      date.strftime("%a %-m/%-d")
    end

    def carrier_phrase(order)
      carrier = order.carrier.to_s
      return nil if carrier.blank? || carrier == "manual"

      tracking = order.tracking_number.to_s.strip
      tracking.present? ? "#{carrier} #{tracking}" : carrier
    end

    def delivery_date(order)
      Date.parse(order.delivery_date.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # ---- writing ------------------------------------------------------------

    # A row nothing emailed us about — something bought somewhere without a
    # parser, or a thing they were told is coming. `carrier: :manual` is what
    # the dashboard's own "add" uses, so these behave identically there.
    def add!(user:, name:, on: nil, tracking: nil, url: nil)
      raise "deliveries aren't part of this person's setup" unless available?(user)
      raise "a delivery needs a name" if name.to_s.strip.blank?

      AmazonOrder.reload
      order = AmazonOrder.create(carrier: :manual)
      order.name = name.to_s.strip
      # THEIR today, not the server's. Time.zone is UTC app-wide, so a package
      # added after 6pm on a UTC-6 calendar would otherwise be filed under
      # tomorrow and read back as "due tomorrow" the moment it was saved.
      order.delivery_date   = on || user.perceived_today
      order.tracking_number = tracking.to_s.strip.presence
      order.custom_url      = url.to_s.strip.presence
      commit!
      order
    end

    # Correcting a row that already exists: the name an email guessed wrong, a
    # day they've since been told, a tracking number that arrived separately.
    # The dashboard can do all of this, but only through a typed command with
    # an inline `{ url: "…" }` block on the end, which is a syntax to remember
    # rather than a thing to say.
    #
    # Only the fields actually passed are touched — nil means "leave it", so a
    # rename can't wipe a tracking number by omission.
    def edit!(user:, match:, name: nil, on: nil, tracking: nil, url: nil)
      raise "deliveries aren't part of this person's setup" unless available?(user)

      order = find(user, match)
      raise "nothing on the way matches #{match.to_s.strip.inspect}" if order.nil?

      order.name            = name.to_s.strip if name.to_s.strip.present?
      order.delivery_date   = on if on.present?
      order.tracking_number = tracking.to_s.strip if tracking.to_s.strip.present?
      order.custom_url      = url.to_s.strip if url.to_s.strip.present?
      commit!
      order
    end

    # Marked, not deleted. `delivered` is the same flag the email parsers set
    # when a confirmation lands, so a hand-marked row and an emailed one read
    # identically — and the row survives to answer "did that ever come".
    def arrived!(user:, match:)
      raise "deliveries aren't part of this person's setup" unless available?(user)

      order = find(user, match)
      raise "nothing on the way matches #{match.to_s.strip.inspect}" if order.nil?

      order.delivered = true
      commit!
      order
    end

    def drop!(user:, match:)
      raise "deliveries aren't part of this person's setup" unless available?(user)

      order = find(user, match)
      raise "nothing on the way matches #{match.to_s.strip.inspect}" if order.nil?

      order.destroy
      commit!
      order
    end

    # Undelivered first: "the desk came" means the one still expected, not the
    # one that arrived last week under the same name.
    #
    # Checks who's asking on its own rather than trusting its callers to: a
    # tool's confirm resolves through here before anything else runs, so this is
    # a place someone else's companion could otherwise read the list from.
    def find(user, match)
      return nil unless available?(user)

      candidates = narrow(orders, match)
      candidates.reject(&:delivered).first || candidates.first
    end

    # Both halves, always. `save` writes the cache and `broadcast` is what makes
    # the dashboard redraw — skipping it leaves the page showing a list that no
    # longer matches what Buddy just said it did.
    def commit!
      AmazonOrder.save
      AmazonOrder.broadcast
    end
  end
end
