# A saved contact's address, read out of their own address book.
#
# Every other path to an address goes INTO something - a drive, a travel time,
# an agenda item's resolved location - and none of them hands the street back,
# so "what's Carlos' address?" had no way to be answered.
Buddy::Tools.register(
  name:        :contact_address,
  summary:     "The address saved for a person or place in their contacts: \"what's Carlos' " \
               "address?\", \"where does Sarah live?\", \"what's the address for the DMV?\".",
  description: <<~TXT,
    Read the address saved on one of their contacts - a person ("Carlos",
    "Sarah's house") or a place they've saved ("the DMV", "Herriman DMV",
    "Momentum Sandy").

    A contact can have several addresses, each with a label. The one the
    phrase names by its label comes back first; otherwise the primary one.
    The others are listed too, so "which one is the Riverton one?" needs no
    second call.

    If nothing in their contacts matches, say so plainly - that's a real
    answer, not a reason to guess an address.
  TXT
  args:        {
    name: { type: :string, required: true, description: "The person or place as they named it" },
  },
  # A read of their own contacts. Nothing is written.
  auto:        true,
  answers:     true,
  confirm:     ->(payload, ctx) {
    book    = AddressBook.new(ctx.user)
    contact = book.match_contact(payload[:name])
    address = contact&.primary_address || book.address_in_phrase(payload[:name])
    contact ||= address&.contact
    raise "no contact matching #{payload[:name].inspect} in their address book" if contact.nil?
    raise "#{contact.name} is saved with no address on it" if address.nil?

    { summary: "Look up #{contact.name}'s address", resolved: { contact_id: contact.id, address_id: address.id, name: contact.name } }
  },
  label:       ->(payload, _ctx) { { title: "📍 #{payload[:name]}", sub: "address" } },
  execute:     ->(payload, ctx) {
    contact = ctx.user.contacts.find_by(id: payload[:contact_id])
    next { name: payload[:name], gone: true } if contact.nil?

    addresses = contact.addresses.ordered.to_a
    picked    = addresses.find { |address| address.id == payload[:address_id] } || addresses.first
    describe  = ->(address) { { street: address.street, label: address.label.presence }.compact }

    {
      name:    contact.name,
      address: picked && describe.call(picked),
      others:  (addresses - [picked]).map(&describe).presence,
    }.compact
  },
)
