Buddy::Tools.register(
  name:        :show_inventory_image,
  description: <<~TXT,
    Put a box's photos in front of them, in this conversation. Use it when the
    picture IS the answer: "show me what's in the camping tote", "what does
    that bin look like", "have we got a photo of the attic shelf" - and when
    you're describing where something is and there's a shot of the shelf it's
    on, because a picture of the right shelf saves the walk.

    `item` is the box or item, a `#HANDLE` off a `search_inventory` row or its
    name. `search_inventory` says on each row whether that thing has photos,
    so you'll usually know before calling.

    It tells you how many went, so speak from that. Nothing there is a real
    answer - say there's no photo of it and offer to save one next time
    they're standing in front of it, rather than describing a picture you
    haven't got. Do not use this to look at a photo yourself: that's
    `view_image`, and it takes a message from the thread.
  TXT
  feature:     :inventory,
  args:        {
    item: { type: :string, required: true, description: "The box or item whose photos to show" },
  },
  auto:        true,
  answers:     true,
  # It posts a real message into the thread, so it stays eligible for a routine
  # the way any other acting call is.
  acts:        true,
  confirm:     ->(payload, ctx) {
    box = Buddy::Inventory.resolve!(ctx.user, payload[:item], verb: "show")
    { summary: "Show the photos of #{box.name}", resolved: { box_key: box.param_key, was_named: box.name } }
  },
  label:       ->(payload, _ctx) { "📷 #{payload[:was_named].presence || payload[:item]}" },
  execute:     ->(payload, ctx) {
    box    = Buddy::Inventory.find!(ctx.user, payload[:box_key])
    images = box.images.ordered.select { |image| image.file.attached? }

    if images.empty?
      next {
        item:   box.name,
        photos: 0,
        how:    "There are NO photos of #{box.name}, and nothing was shown. Say that plainly - " \
                "don't describe it. It's in #{Buddy::Inventory.location_of(box)} if that helps, " \
                "and they can send you a shot of it any time to save for next time.",
      }
    end

    Buddy::Inventory.post_photos!(conversation: ctx.conversation, user: ctx.user, box: box, images: images)

    {
      item:     box.name,
      where:    Buddy::Inventory.location_of(box),
      photos:   images.length,
      captions: images.filter_map(&:caption).presence,
      how:      "#{images.length} #{"photo".pluralize(images.length)} of #{box.name} #{images.length == 1 ? "is" : "are"} " \
                "in the thread now, just above your reply - they can see #{images.length == 1 ? "it" : "them"}. " \
                "Say something about it in a line rather than announcing that you've sent a photo, and " \
                "don't describe what's in the picture: you haven't looked at it.",
    }.compact
  },
)
