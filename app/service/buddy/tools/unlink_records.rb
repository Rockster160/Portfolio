Buddy::Tools.register(
  name:        :unlink_records,
  description: <<~TXT,
    Break a pairing, so one thing stops following another - "logging coffee
    shouldn't tick off the chore any more", "unlink those two".

    `name` is either end of the pairing. Give `other` as well when that end is
    in more than one pairing.

    To change how a pairing behaves, don't unlink it first: link_records on the
    same pair replaces it.
  TXT
  args:        {
    name:  { type: :string, required: true,  description: "Either end of the pairing" },
    other: { type: :string, required: false, description: "The far end, if the first is in several pairings" },
  },
  routinable:  false,
  confirm:     ->(payload, ctx) {
    found = Buddy::LinkFinder.matching(ctx.user, payload[:name], payload[:other])
    raise "nothing is linked to #{payload[:name].inspect}" if found.empty?
    # Naming the options beats silently unlinking the first of three.
    if found.length > 1
      raise "#{payload[:name]} is in #{found.length} pairings - say which: #{found.map(&:summary).join("; ")}"
    end

    { summary: "Unlink #{found.first.summary}?", resolved: { link_id: found.first.id, label: found.first.sentence } }
  },
  label:       ->(payload, _ctx) { { title: "Unlink #{payload[:label]}" } },
  execute:     ->(payload, ctx) {
    link = RecordLink.find_by(id: payload[:link_id], user_id: ctx.user.id)
    raise "that link is already gone" if link.nil?

    attrs = link.attributes.except("id", "created_at", "updated_at")
    label = link.sentence
    link.destroy!
    {
      label:  label,
      revert: { op: "recreated", model: "RecordLink", attrs: attrs, summary: "put that link back" },
    }
  },
  receipt:     ->(result, _ctx) { "Unlinked: #{result[:label]} ✓" },
)
