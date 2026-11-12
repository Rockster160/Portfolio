# Saves a person or place into their own address book, with the address on it.
#
# A name already in the book gets the address added to that contact rather than
# a second contact with the same name, so "save Carlos' new address" and "add
# Carlos as a contact" both land on the one Carlos.
Buddy::Tools.register(
  name:        :add_contact,
  summary:     "Save a NEW person or place to their contacts, with its address, phone or email - " \
               "or a new address onto a contact they already have.",
  description: <<~TXT,
    Save someone or somewhere to their contacts: "add Whit as a contact,
    1234 E Main St, Sandy", "save the Riverton DMV's address, it's 12830 S
    Redwood Rd", "put Sarah's number in my contacts, 801-555-0134".

    `name` is the person or place as they'd look it up later - "Whit", "DMV" -
    not "Whit's house". `address` is the street as they gave it, city and all
    when they said it. `label` names which address this is when a contact has
    several ("work", "Riverton"); leave it off otherwise. `phone` and `email`
    only when they gave them.

    A name that's already in their contacts gets the address added to that
    contact - there is never a second contact with the same name.
  TXT
  args:        {
    name:    { type: :string, required: true,  description: "The person or place, as they'd look it up" },
    address: { type: :string, required: false, description: "The street address as they gave it" },
    label:   { type: :string, required: false, description: "Which address this is, when it needs telling apart" },
    phone:   { type: :string, required: false, description: "Phone number, only when given" },
    email:   { type: :string, required: false, description: "Email address, only when given" },
  },
  confirm:     ->(payload, ctx) {
    name   = payload[:name].to_s.strip
    lines  = payload[:address].to_s.split("\n").map { |line| line.squish.delete_suffix(",") }
    street = lines.compact_blank.join(", ").presence
    raise "no name to save the contact under" if name.blank?
    raise "nothing to save for #{name}" if [street, payload[:phone], payload[:email]].all?(&:blank?)

    existing = ctx.user.contacts.name_find(name)
    if existing && street && existing.addresses.exists?(["street ILIKE ?", street])
      raise "#{existing.name} already has #{street} saved"
    end

    detail = [street, payload[:phone].presence, payload[:email].presence].compact.join(" · ")
    summary = (
      if existing
        "Add #{detail} to #{existing.name}?"
      else
        "Add #{name} to contacts with #{detail}?"
      end
    )

    { summary: summary, resolved: { name: existing&.name || name, address: street, contact_id: existing&.id } }
  },
  label:       ->(payload, _ctx) {
    sub = [payload[:address], payload[:phone], payload[:email]].compact_blank.join("\n")
    { title: "👤 #{payload[:name]}", sub: sub.presence || "contact" }
  },
  merge_key:   ->(payload) { "add_contact:#{payload[:name].to_s.downcase.strip}" },
  # A misheard street corrected in the next message is the same contact being
  # saved once.
  supersedes:  :pending,
  execute:     ->(payload, ctx) {
    contact = payload[:contact_id] && ctx.user.contacts.find_by(id: payload[:contact_id])
    created = contact.nil?
    contact ||= ctx.user.contacts.create!(name: payload[:name])

    updates = { phone: payload[:phone].presence, email: payload[:email].presence }.compact
    contact.update!(updates) if updates.any?

    if payload[:address].present?
      # The map location is what travel times and "where am I" read; an address
      # that doesn't geocode is still worth keeping as typed.
      lat, lng = AddressBook.new(ctx.user).loc_from_address(payload[:address])
      contact.addresses.create!(
        user:    ctx.user,
        street:  payload[:address],
        label:   payload[:label].presence,
        primary: !contact.addresses.exists?,
        lat:     lat,
        lng:     lng,
      )
    end

    { name: contact.name, contact_id: contact.id, created: created, address: payload[:address] }.compact
  },
  receipt:     ->(result, _ctx) {
    where = result[:address] ? " at #{result[:address]}" : ""
    result[:created] ? "Added **#{result[:name]}** to contacts#{where} ✓" : "Saved to **#{result[:name]}**#{where} ✓"
  },
)
