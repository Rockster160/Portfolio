Buddy::Tools.register(
  name:        :cancel_reminder,
  description: <<~TXT,
    Remove a pending reminder OR a condition-based watch. Use when the person
    says "nevermind that reminder", "don't remind me about X anymore", "cancel
    the vet reminder", "stop watching for the doorbell", "delete that one".

    This DELETES it. There's no disabled-but-still-there state, so "cancel it"
    and "delete it" are the same call and you never have to explain a
    difference between them.

    `match` is a substring of the text OR the numeric id from
    `upcoming_reminders` / `active_watches`. **Prefer the id.** Several of these
    can carry word-for-word identical text - two doorbell watches both reading
    "Someone's at the doorbell" differ only in what they listen for - and a
    substring cannot tell those apart. When it can't, this refuses and lists
    them rather than guessing, and you pick by id.

    Those context sections also show rows the person switched OFF from the
    panel, marked `status: off`. Those still exist and can still be removed;
    they just aren't running. Don't describe one as gone, and don't reach for a
    live one because the off one didn't look like a match.
  TXT
  args:        {
    match: { type: :string, required: true, description: "Numeric id (preferred), or a substring to match" },
  },
  # Cancelling matches whatever is pending right now, which is never the same
  # set twice - a saved copy would retire a reminder they still want.
  routinable:  false,
  # Level 2: the row goes now and comes back if they untick it.
  #
  # Untyped, this defaulted to 3 - a plain pending checkbox - while the tools
  # that CREATE these are level 1 on the reasoning that setting one is safe
  # because cancel_reminder undoes it. Removing one is exactly as reversible and
  # already carries the proof: `execute` returns PendingLookup's `recreated`
  # descriptor, holding every column, and Reverter lists both BuddyReminder and
  # BuddyWatch. What it cost was a reminder firing 47 minutes after the person
  # said to stop it (prod 3849 -> 3855), because the card sat untapped and
  # nothing about "you can clear it off" reads as "this is still on".
  level:       2,
  confirm:     ->(payload, ctx) {
    needle = payload[:match].to_s.strip
    raise "which one?" if needle.empty?

    found = Buddy::PendingLookup.matching(ctx.user, needle)
    raise "nothing matches #{needle.inspect} - it may already be gone" if found.empty?

    # Naming the options beats deleting the wrong one of three.
    if found.length > 1
      raise "#{found.length} of those match and they're worded the same - say which by id: " \
            "#{found.map(&:disambiguated).join("; ")}"
    end

    row  = found.first
    note = row.off? ? " (already switched off)" : ""
    { summary: "Remove #{row.noun} #{row.summary}?#{note}", resolved: { record_type: row.kind, record_id: row.id } }
  },
  label:       ->(payload, ctx) {
    row = Buddy::PendingLookup.find(ctx.user, payload[:record_type], payload[:record_id])
    next { title: "Remove reminder" } if row.nil?

    # The sub is what makes two identical-looking rows tellable apart on the
    # card. Prod 2817: three cancel rows in a row all read "Cancel 🔔 Someone's
    # at the doorbell." and two of them were the wrong watch.
    { title: "Remove #{row.summary}", sub: row.detail }
  },
  execute:     ->(payload, ctx) {
    row = Buddy::PendingLookup.find(ctx.user, payload[:record_type], payload[:record_id])
    raise "that one's already gone" if row.nil?

    { noun: row.noun, summary: row.summary, detail: row.detail, revert: row.destroy! }
  },
  receipt:     ->(result, _ctx) {
    # Naming it is the point. "Reminder cancelled ✓" three times over, for three
    # different rows, told the person nothing about which one went.
    ["Removed #{result[:noun]} #{result[:summary]}", result[:detail].presence].compact.join(" · ") + " ✓"
  },
)
