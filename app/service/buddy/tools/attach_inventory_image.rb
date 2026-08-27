Buddy::Tools.register(
  name:        :attach_inventory_image,
  description: <<~TXT,
    Put a photo they've sent onto a thing in the inventory, so next time the
    answer to "what's in that tote" is a picture of what's in it.

    Use it when they send a photo and say where it belongs: "this is the
    camping tote", "here's what's in the attic bin", "save this to the tool
    cubes". Also when they've just been told where something is and send a
    shot of it - a photo with a box named anywhere near it is almost always
    this.

    `item` is the box or item it belongs to, a `#HANDLE` or a name. The photo
    is the most recent image in this conversation unless you pass a
    `message_id` - their earlier messages show images as `[image #1234:
    name.jpg]`, and that number is what goes there. `caption` is a short line
    for what the picture shows ("the lids are underneath"), and it's worth
    writing: a photo with no caption is one more thing to open.

    This SAVES the picture; it doesn't look at it. To actually see what's in
    a photo - to read a label, or count what's in the shot - that's
    `view_image`, and doing that first is usually the better order, because
    then the caption can say what's in it.

    A box can have several photos and this adds one rather than replacing what
    is already there.
  TXT
  feature:     :inventory,
  args:        {
    item:       { type: :string,  required: true,  description: "The box or item the photo belongs to" },
    message_id: { type: :integer, required: false, description: "Id from `[image #1234: ...]` - omit for the most recent photo" },
    caption:    { type: :string,  required: false, description: "Short line for what the picture shows" },
  },
  confirm:     ->(payload, ctx) {
    raise "there's no conversation here to take a photo from" if ctx.conversation.nil?

    box = Buddy::Inventory.resolve!(ctx.user, payload[:item], verb: "put the photo on")

    scope = ctx.conversation.byte_messages.with_attached_files
    message = (
      if payload[:message_id].present?
        scope.find_by(id: payload[:message_id]) || raise("no message ##{payload[:message_id]} in this conversation")
      else
        scope.recent.limit(Buddy::GPT::ImageTool::SEARCH_DEPTH).find { |m| Buddy::Inventory.images_on(m).any? }
      end
    )
    raise "there aren't any photos in this conversation to put on #{box.name}" if message.nil?
    raise "message ##{message.id} hasn't got a photo on it" if Buddy::Inventory.images_on(message).empty?

    count = Buddy::Inventory.images_on(message).length
    {
      summary:  "Put #{count == 1 ? "that photo" : "those #{count} photos"} on #{box.name}?",
      resolved: { box_key: box.param_key, was_named: box.name, message_id: message.id, count: count },
    }
  },
  label:       ->(payload, _ctx) {
    { title: "📷 #{payload[:was_named].presence || payload[:item]}", sub: payload[:caption].presence || "photo from the thread" }
  },
  # Level 2: it lands straight away with the row pre-checked, and unticking
  # takes the photo back off. Same as anything else that files something.
  level:       2,
  execute:     ->(payload, ctx) {
    box     = Buddy::Inventory.find!(ctx.user, payload[:box_key])
    message = ctx.conversation.byte_messages.with_attached_files.find(payload[:message_id])
    files   = Buddy::Inventory.images_on(message)
    added   = files.map { |file|
      image = box.images.create!(user: ctx.user, caption: payload[:caption].presence)
      image.file.attach(Buddy::Inventory.copy_blob(file.blob))
      image
    }
    box.broadcast!
    # Against the ORIGINAL blobs, not the copies. Filing a photo makes a second
    # blob of the same picture, and describing that would put a second sentence
    # on one photo and return it twice; what this does instead is add the box to
    # the row the chat message already has, so it can be found either way.
    DescribeImageWorker.enqueue_for(
      user:         ctx.user,
      blobs:        files.map(&:blob),
      taken_at:     message.created_at,
      byte_message: message,
      box_key:      box.param_key,
    )

    {
      box_key: box.param_key,
      item:    box.name,
      count:   added.length,
      reverts: added.map { |image|
        { op: "created", model: "BoxImage", id: image.id, summary: "took that photo back off #{box.name}" }
      },
    }
  },
  receipt:     ->(result, _ctx) {
    "Saved #{result[:count] == 1 ? "that photo" : "#{result[:count]} photos"} to **#{result[:item]}** ✓"
  },
)
