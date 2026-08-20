module Shipments
  # Decides whether a forwarded SMS is a per-package carrier update worth
  # parsing. Used by ReceiveSmsWorker as the hardcoded carrier gate (mirrors
  # ReceiveEmailWorker#amazon_update?). Deliberately conservative: anything it
  # doesn't recognize falls through to the Slack notifier untouched.
  module SmsRouter
    module_function

    # Digest texts carry no per-package identity ("You have 2 packages
    # estimated for delivery today. Manage your deliveries: …") — ignore them.
    DIGEST_REGEX = /you have \d+ packages? estimated/i

    # A specific-package UPS text: names the sender's package, a tracking
    # number, or a same-day/next-day delivery. Excludes the digest above.
    UPS_PACKAGE_REGEX = /your .+? package|delivering (?:today|tomorrow)|\b1Z[0-9A-Z]{16}\b|Delivered your/i

    # Wayfair texts a shipment status; it also texts a great deal of marketing,
    # and both carry a wayfair.com short link. The status VOCABULARY is what
    # separates them — "Track your desk here" alone is a sale email's shape too.
    WAYFAIR_PACKAGE_REGEX = /out for delivery|(?:has|have) shipped|on (?:its|the) way|\bdelivered\b|arriv(?:ing|es|ed)|estimated delivery|delivery (?:date|window)/i

    def match?(text)
      ups?(text) || wayfair?(text)
    end

    def ups?(text)
      t = text.to_s
      return false if t.match?(DIGEST_REGEX)
      return false unless t.match?(/\bUPS\b/i)

      t.match?(UPS_PACKAGE_REGEX)
    end

    def wayfair?(text)
      t = text.to_s
      return false unless t.match?(/\bWayfair\b/i)

      t.match?(WAYFAIR_PACKAGE_REGEX)
    end
  end
end
