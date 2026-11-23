module AppDevices
  # A person's hot links: one list for every phone they're signed in on, each
  # widget picking its own from it under Edit Widget.
  module HotLinks
    module_function

    KINDS = [
      :open,
      :command,
      :buddy,
      :task,
      :routine,
      :trigger,
      :check_in,
      :prompt,
      :list_toggle,
      :url,
    ].freeze
    # iOS shows the first four on the app icon; the rest still reach widgets,
    # Control Center and Shortcuts.
    MAX = 12
    # The app icon's long-press menu draws SF Symbols only, so a hot link's icon
    # is one of these, named for searching.
    SYMBOLS = {
      "bolt.fill"                           => "Bolt",
      "star.fill"                           => "Star",
      "heart.fill"                          => "Heart",
      "flag.fill"                           => "Flag",
      "bell.fill"                           => "Bell",
      "bookmark.fill"                       => "Bookmark",
      "tag.fill"                            => "Tag",
      "sparkles"                            => "Sparkles",
      "flame.fill"                          => "Flame",
      "bubble.left.fill"                    => "Message",
      "bubble.left.and.bubble.right.fill"   => "Conversation",
      "text.bubble.fill"                    => "Text bubble",
      "phone.fill"                          => "Phone",
      "envelope.fill"                       => "Mail",
      "paperplane.fill"                     => "Send",
      "mic.fill"                            => "Microphone",
      "questionmark.circle.fill"            => "Question",
      "checkmark.circle.fill"               => "Check",
      "plus.circle.fill"                    => "Plus",
      "list.bullet"                         => "List",
      "checklist"                           => "Checklist",
      "square.and.pencil"                   => "Note",
      "doc.text.fill"                       => "Document",
      "calendar"                            => "Calendar",
      "clock.fill"                          => "Clock",
      "timer"                               => "Timer",
      "alarm.fill"                          => "Alarm",
      "stopwatch.fill"                      => "Stopwatch",
      "hourglass"                           => "Hourglass",
      "house.fill"                          => "House",
      "building.2.fill"                     => "Office",
      "door.left.hand.open"                 => "Door",
      "door.garage.closed"                  => "Garage",
      "lock.fill"                           => "Lock",
      "lock.open.fill"                      => "Unlock",
      "key.fill"                            => "Key",
      "lightbulb.fill"                      => "Light",
      "lamp.desk.fill"                      => "Lamp",
      "fan.fill"                            => "Fan",
      "thermometer.medium"                  => "Thermometer",
      "snowflake"                           => "Snowflake",
      "sun.max.fill"                        => "Sun",
      "moon.fill"                           => "Moon",
      "cloud.rain.fill"                     => "Rain",
      "umbrella.fill"                       => "Umbrella",
      "bed.double.fill"                     => "Bed",
      "sofa.fill"                           => "Sofa",
      "tv.fill"                             => "TV",
      "washer.fill"                         => "Washer",
      "dishwasher.fill"                     => "Dishwasher",
      "trash.fill"                          => "Trash",
      "spigot.fill"                         => "Tap",
      "shower.fill"                         => "Shower",
      "car.fill"                            => "Car",
      "bus.fill"                            => "Bus",
      "bicycle"                             => "Bicycle",
      "airplane"                            => "Airplane",
      "fuelpump.fill"                       => "Fuel",
      "bolt.car.fill"                       => "Car charging",
      "map.fill"                            => "Map",
      "location.fill"                       => "Location",
      "mappin.and.ellipse"                  => "Pin",
      "signpost.right.fill"                 => "Directions",
      "figure.walk"                         => "Walking",
      "figure.run"                          => "Running",
      "figure.strengthtraining.traditional" => "Weights",
      "figure.yoga"                         => "Yoga",
      "dumbbell.fill"                       => "Dumbbell",
      "drop.fill"                           => "Water",
      "cup.and.saucer.fill"                 => "Coffee",
      "mug.fill"                            => "Mug",
      "wineglass.fill"                      => "Wine",
      "fork.knife"                          => "Food",
      "carrot.fill"                         => "Carrot",
      "birthday.cake.fill"                  => "Cake",
      "cart.fill"                           => "Cart",
      "bag.fill"                            => "Bag",
      "creditcard.fill"                     => "Card",
      "dollarsign.circle.fill"              => "Money",
      "gift.fill"                           => "Gift",
      "pills.fill"                          => "Pills",
      "cross.case.fill"                     => "First aid",
      "heart.text.square.fill"              => "Health",
      "bandage.fill"                        => "Bandage",
      "brain.head.profile"                  => "Mind",
      "face.smiling"                        => "Smile",
      "person.fill"                         => "Person",
      "person.2.fill"                       => "People",
      "figure.and.child.holdinghands"       => "Family",
      "dog.fill"                            => "Dog",
      "cat.fill"                            => "Cat",
      "pawprint.fill"                       => "Paw",
      "leaf.fill"                           => "Leaf",
      "tree.fill"                           => "Tree",
      "camera.fill"                         => "Camera",
      "photo.fill"                          => "Photo",
      "music.note"                          => "Music",
      "headphones"                          => "Headphones",
      "speaker.wave.2.fill"                 => "Speaker",
      "play.fill"                           => "Play",
      "gamecontroller.fill"                 => "Game",
      "book.fill"                           => "Book",
      "graduationcap.fill"                  => "School",
      "briefcase.fill"                      => "Work",
      "hammer.fill"                         => "Hammer",
      "wrench.and.screwdriver.fill"         => "Tools",
      "paintbrush.fill"                     => "Paint",
      "scissors"                            => "Scissors",
      "printer.fill"                        => "Printer",
      "desktopcomputer"                     => "Computer",
      "laptopcomputer"                      => "Laptop",
      "iphone"                              => "iPhone",
      "wifi"                                => "Wi-Fi",
      "battery.100"                         => "Battery",
      "power"                               => "Power",
      "gearshape.fill"                      => "Settings",
      "magnifyingglass"                     => "Search",
      "link"                                => "Link",
      "globe"                               => "Globe",
      "chart.bar.fill"                      => "Chart",
      "chart.line.uptrend.xyaxis"           => "Trend",
      "gauge.with.dots.needle.33percent"    => "Gauge",
      "shippingbox.fill"                    => "Package",
      "archivebox.fill"                     => "Archive",
      "tray.full.fill"                      => "Inbox",
    }.freeze

    # Saves the list and tells every phone to pick it up.
    def save!(user, list)
      user.update!(hot_links: clean(list))
      user.app_devices.active.find_each { |device| device.nudge!(settings: true) }
    end

    def clean(list)
      Array(list).first(MAX).filter_map { |link|
        link = link.to_h.deep_stringify_keys
        action = link["action"].to_h
        next if link["title"].to_s.strip.blank?
        next unless KINDS.include?(action["kind"].to_s.to_sym)

        {
          id:       link["id"].presence || SecureRandom.uuid,
          title:    link["title"].to_s.strip,
          subtitle: link["subtitle"].to_s.strip.presence,
          icon:     link["icon"].to_s.strip.presence || "bolt.fill",
          action:   clean_action(action),
        }.compact
      }
    end

    def clean_action(action)
      {
        kind:        action["kind"].to_s,
        value:       action["value"].to_s.strip.presence,
        send_as:     [:buddy, :command].find { |kind| kind.to_s == action["send_as"].to_s }&.to_s,
        prefix:      action["prefix"].to_s.presence,
        placeholder: action["placeholder"].to_s.strip.presence,
        data:        json_data(action["data"]),
        inline:      ActiveModel::Type::Boolean.new.cast(action["inline"]),
      }.compact
    end

    def json_data(raw)
      return raw if raw.is_a?(Hash)
      return if raw.to_s.strip.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      raise ArgumentError, "A hot link's data isn't valid JSON: #{raw.to_s.truncate(40)}"
    end
  end
end
