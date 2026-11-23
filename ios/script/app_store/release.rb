require "digest"
require_relative "build"

module AppStore
  # bin/release: a version to App Review and the store. Picks the version,
  # takes a build already on TestFlight (or makes one), fills in what the store
  # listing and App Review need, asking for what only a person knows, pauses on
  # what only the website can do, and submits.
  class Release < Flow
    # appVersionState, by what the script can do with a version in it.
    EDITABLE = %w[
      PREPARE_FOR_SUBMISSION
      READY_FOR_REVIEW
      DEVELOPER_REJECTED
      REJECTED
      METADATA_REJECTED
      INVALID_BINARY
    ].freeze
    LIVE = %w[READY_FOR_DISTRIBUTION READY_FOR_SALE].freeze
    WITH_APPLE = %w[
      WAITING_FOR_REVIEW
      IN_REVIEW
      ACCEPTED
      PENDING_APPLE_RELEASE
      PROCESSING_FOR_DISTRIBUTION
      WAITING_FOR_EXPORT_COMPLIANCE
    ].freeze
    AWAITING_RELEASE = "PENDING_DEVELOPER_RELEASE".freeze
    # The store's 6.9 inch iPhone screenshots, the one size it requires.
    SCREENSHOT_TYPE = "APP_IPHONE_67".freeze
    SCREENSHOT_SIZES = [[1320, 2868], [1290, 2796], [1260, 2736]].freeze
    UNLISTED = "https://developer.apple.com/support/unlisted-app-distribution/".freeze
    RELEASES = [
      ["Release it on the store right away", "AFTER_APPROVAL"],
      ["Wait for me to release it", "MANUAL"],
    ].freeze
    REVIEW_FIELDS = [
      [:contactFirstName, "Contact first name"],
      [:contactLastName, "Contact last name"],
      [:contactPhone, "Contact phone (+1 555 555 5555)"],
      [:contactEmail, "Contact email"],
      [:demoAccountName, "Demo account email"],
      [:demoAccountPassword, "Demo account password"],
      [:notes, "Notes for the reviewer"],
    ].freeze

    def run
      title("#{config.name} to the App Store")
      versions = connect.list("/v1/apps/#{app[:id]}/appStoreVersions", { "filter[platform]": :IOS })
      return if with_apple?(versions)

      live = versions.find { |version| LIVE.include?(state(version)) }
      editable = versions.find { |version| EDITABLE.include?(state(version)) }
      number = pick_version(live, editable)
      build = pick_build(number)
      version = store_version(editable, number)
      attach(version, build)
      listing(version, first: live.nil?)
      app_information
      screenshots(version)
      review_details(version, versions)
      once_on_the_website
      submit(version, build)
    end

    private

    def state(version)
      version.dig(:attributes, :appVersionState) || version.dig(:attributes, :appStoreState)
    end

    def version_string(version) = version.dig(:attributes, :versionString)
    def version_page = website("the version being prepared", "distribution/ios/version/inflight")
    def link(...) = Connect.link(...)

    # A version already with Apple: released here when it waits on that, or reported.
    def with_apple?(versions)
      waiting = versions.find { |version| state(version) == AWAITING_RELEASE }
      if waiting
        step("#{version_string(waiting)} is approved")
        if yes?("Release it on the store now?")
          connect.create(:appStoreVersionReleaseRequests, {}, appStoreVersion: link(waiting))
          done("Released; it reaches the store within a few hours")
        end
        return true
      end

      busy = versions.find { |version| WITH_APPLE.include?(state(version)) }
      return false unless busy

      step("#{version_string(busy)} is with Apple: #{state(busy).downcase.tr("_", " ")}")
      say(version_page.last)
      true
    end

    def pick_version(live, editable)
      step("Version")
      live_number = live && version_string(live)
      say("Live on the store: #{live_number}") if live
      suggested = editable ? version_string(editable) : marketing_version
      suggested = bump(live_number) if live && !newer?(suggested, live_number)
      number = loop do
        answer = ask("Version people see", default: suggested)
        shaped = answer.match?(/\A\d+(\.\d+){0,2}\z/)
        break answer if shaped && (live.nil? || newer?(answer, live_number))

        warn("A version is numbers like 1.2 or 1.2.3, higher than the live one")
      end
      return number if number == marketing_version

      self.marketing_version = number
      warn("project.yml now says #{number}; ship that change so the next build carries it")
      number
    end

    def newer?(version, than) = Gem::Version.new(version) > Gem::Version.new(than)

    def bump(version)
      parts = version.split(".").map(&:to_i)
      parts << 0 if parts.size < 2
      parts[1] += 1
      parts[0..1].join(".")
    end

    # A build of this version already on TestFlight, or a new one.
    def pick_build(number)
      builder = Build.new(self)
      tested = builder.recent(
        "filter[preReleaseVersion.version]": number,
        "filter[processingState]":           "PROCESSING,VALID",
        "filter[expired]":                   false,
      ).first
      if tested
        attributes = tested[:attributes]
        step("Build")
        say("#{number} (#{attributes[:version]}), uploaded #{ago(attributes[:uploadedDate])}")
        if yes?("Send this build, the one on TestFlight?")
          return builder.processed(attributes[:version], number)
        end
      end
      builder.processed(builder.make, number)
    end

    def store_version(editable, number)
      unless editable
        attributes = { platform: :IOS, versionString: number }
        return connect.create(:appStoreVersions, attributes, app: link(app))
      end
      return editable if version_string(editable) == number

      connect.update(:appStoreVersions, editable[:id], { versionString: number })
    end

    def attach(version, build)
      connect.update(:appStoreVersions, version[:id], {}, build: link(build))
      done("#{version_string(version)} takes build #{build.dig(:attributes, :version)}")
    end

    # [field, question, default] of the listing's words asked once.
    def listing_questions
      [
        [:description, "Description", config.description],
        [:keywords, "Keywords", config.keywords],
        [:supportUrl, "Support URL", config.support_url],
      ]
    end

    def english(records)
      records.find { |record| record.dig(:attributes, :locale) == "en-US" } || records.first
    end

    def localization(version)
      english(connect.list("/v1/appStoreVersions/#{version[:id]}/appStoreVersionLocalizations"))
    end

    # The store page's words. Set ones are kept; What's New is asked on every update.
    def listing(version, first:)
      step("Store listing")
      entry = localization(version)
      current = entry[:attributes]
      changes = {}
      listing_questions.each do |field, question, default|
        changes[field] = ask(question, default: default) if current[field].to_s.empty?
      end
      unless first
        say("The store shows this under What's New for this version.")
        suggested = current[:whatsNew] || changes_since(:released_through) || config.update_note
        changes[:whatsNew] = ask("What's New", default: suggested)
      end
      connect.update(:appStoreVersionLocalizations, entry[:id], changes) unless changes.empty?
      done("Listing filled in")
    end

    def app_information
      step("App information")
      info = connect.list("/v1/apps/#{app[:id]}/appInfos").find { |found|
        EDITABLE.include?(found.dig(:attributes, :state) || found.dig(:attributes, :appStoreState))
      }
      return warn("No app information open for changes") unless info

      privacy_policy(info)
      category(info)
      content_rights
      age_rating(info)
    end

    def privacy_policy(info)
      entry = english(connect.list("/v1/appInfos/#{info[:id]}/appInfoLocalizations"))
      if entry.dig(:attributes, :privacyPolicyUrl).to_s.empty?
        url = ask("Privacy policy URL", default: config.privacy_url)
        connect.update(:appInfoLocalizations, entry[:id], { privacyPolicyUrl: url })
      end
      done("Privacy policy URL set")
    end

    def category(info)
      if connect.record("/v1/appInfos/#{info[:id]}/primaryCategory").nil?
        picked = choose("Store category", config.categories)
        connect.update(:appInfos, info[:id], {}, primaryCategory: link(:appCategories, picked))
      end
      done("Category set")
    end

    def content_rights
      if app.dig(:attributes, :contentRightsDeclaration).nil?
        say(config.third_party_hint) if config.third_party_hint
        question = "Does #{config.name} show content made by others that you have the right to show?"
        uses = yes?(question, default: false)
        declared = uses ? :USES_THIRD_PARTY_CONTENT : :DOES_NOT_USE_THIRD_PARTY_CONTENT
        connect.update(:apps, app[:id], { contentRightsDeclaration: declared })
      end
      done("Content rights declared")
    end

    # Its questions change as Apple adds them, so they are answered on the website.
    def age_rating(info)
      loop do
        rating = connect.record("/v1/appInfos/#{info[:id]}/ageRatingDeclaration")
        break done("Age rating answered") if rating && !rating[:attributes].values.compact.empty?

        warn("The age rating hasn't been answered")
        pause(config.age_rating_steps, page: website("App Information", "distribution/info"))
      end
    end

    def screenshots(version)
      step("Screenshots (6.9 inch iPhone)")
      entry = localization(version)
      loop do
        set = screenshot_set(entry)
        count = set ? connect.list("/v1/appScreenshotSets/#{set[:id]}/appScreenshots").size : 0
        break done("#{count} screenshots") if count.positive?

        sizes = SCREENSHOT_SIZES.map { |size| size.join(" x ") }.join(", ")
        say("The store needs 3 to 10, #{sizes}:")
        say("run the app on the iPhone 18 Pro Max simulator, signed in to the demo account,")
        say("and press Cmd-S on each screen to save it to the Desktop.")
        folder = ask("A folder of them (Enter to add them on the website)", required: false)
        if folder.empty?
          pause(
            [
              "Scroll to Previews and Screenshots, iPhone, 6.9\" Display.",
              "Drag the screenshots in, then click Save at the top right.",
            ],
            page: version_page,
          )
        else
          upload_screenshots(entry, set, dragged(folder))
        end
      end
    end

    def screenshot_set(entry)
      sets = connect.list("/v1/appStoreVersionLocalizations/#{entry[:id]}/appScreenshotSets")
      sets.find { |set| set.dig(:attributes, :screenshotDisplayType) == SCREENSHOT_TYPE }
    end

    def upload_screenshots(entry, set, folder)
      files = Dir.glob(File.join(folder, "*.{png,PNG,jpg,jpeg}"))
      files = files.sort.select { |file| screenshot_size?(file) }.first(10)
      return warn("No screenshots of those sizes in #{folder}") if files.empty?

      set ||= connect.create(
        :appScreenshotSets,
        { screenshotDisplayType: SCREENSHOT_TYPE },
        appStoreVersionLocalization: link(entry),
      )
      files.each { |file| upload_screenshot(set, file) }
    end

    def screenshot_size?(file)
      command = ["sips", "-g", "pixelWidth", "-g", "pixelHeight", file]
      output = IO.popen(command, err: File::NULL, &:read)
      size = [output[/pixelWidth: (\d+)/, 1].to_i, output[/pixelHeight: (\d+)/, 1].to_i]
      fits = SCREENSHOT_SIZES.any? { |allowed| [allowed, allowed.reverse].include?(size) }
      return true if fits

      warn("#{File.basename(file)} is #{size.join(" x ")}, not a 6.9 inch size: left out")
      false
    end

    def upload_screenshot(set, file)
      bytes = File.binread(file)
      shot = connect.create(
        :appScreenshots,
        { fileName: File.basename(file), fileSize: bytes.bytesize },
        appScreenshotSet: link(set),
      )
      shot.dig(:attributes, :uploadOperations).each { |operation| connect.upload(operation, bytes) }
      checksum = Digest::MD5.hexdigest(bytes)
      connect.update(:appScreenshots, shot[:id], { uploaded: true, sourceFileChecksum: checksum })
      done("Uploaded #{File.basename(file)}")
    end

    # The person Apple calls and the account its reviewer signs in with, carried
    # over from the last version that had them.
    def review_details(version, versions)
      step("App Review")
      detail = connect.record("/v1/appStoreVersions/#{version[:id]}/appStoreReviewDetail")
      saved = (detail&.dig(:attributes) || {}).compact
      known = earlier_review_details(version, versions).merge(saved)
      say("Apple's reviewer signs in with a demo account: realistic data, no real clients,")
      say("and no authenticator code. The contact is who Apple calls with questions.")
      attributes = REVIEW_FIELDS.to_h { |field, question|
        default = field == :notes ? known[:notes] || config.review_notes : known[field]
        [field, ask(question, default: default, secret: field == :demoAccountPassword)]
      }
      attributes[:demoAccountRequired] = true
      if detail
        connect.update(:appStoreReviewDetails, detail[:id], attributes)
      else
        connect.create(:appStoreReviewDetails, attributes, appStoreVersion: link(version))
      end
      done("Review details saved")
    end

    def earlier_review_details(version, versions)
      versions.each do |other|
        next if other[:id] == version[:id]

        found = connect.record("/v1/appStoreVersions/#{other[:id]}/appStoreReviewDetail")
        return found[:attributes].compact if found&.dig(:attributes, :contactEmail)
      end
      {}
    end

    # What the API can't reach, done once on the website and remembered on this Mac.
    def once_on_the_website
      privacy = website("App Privacy", "distribution/privacy")
      website_step(:app_privacy, config.app_privacy_steps, privacy)
      website_step(
        :pricing,
        [
          "Under Price Schedule, click Add Pricing: United States, Free ($0.00).",
          "Under App Availability, choose the countries (United States), then Save.",
        ],
        website("Pricing and Availability", "distribution/pricing"),
      )
      website_step(
        :unlisted,
        [
          "Sign in with the same Apple Account, and open the request form linked on the page.",
          <<~TEXT.chomp,
            Give the app's name, its Apple ID (#{app[:id]}), and who it is for:
            #{config.audience}.
          TEXT
          "Submit. Apple answers by email; the link to hand out then shows in App Store Connect.",
        ],
        ["Apple's unlisted distribution page", UNLISTED],
      )
    end

    def website_step(key, text, page)
      return if Array(settings[:done]).include?(key.to_s)

      step("On the website (once)")
      pause(text, page: page)
      save(done: Array(settings[:done]) | [key.to_s])
    end

    # Each refusal lists what is missing; fixed on the website, it is tried again.
    def submit(version, build)
      step("Submit")
      current = version.dig(:attributes, :releaseType) || "AFTER_APPROVAL"
      release = choose("Once Apple approves it", RELEASES, default: current)
      connect.update(:appStoreVersions, version[:id], { releaseType: release })
      label = "#{version_string(version)} (#{build.dig(:attributes, :version)})"
      raise Interrupt unless yes?("Submit #{label} for App Review?")

      begin
        send_for_review(version)
      rescue Connect::Refused => e
        warn("App Store Connect needs more before it takes the submission:")
        e.problems.each { |problem| say("  #{problem}") }
        pause("Fix each of those on the page, saving as you go.", page: version_page)
        retry
      end
      note_changes(:released_through)
      done("#{label} is waiting for review; most take a day or two, and Apple emails each step")
      say(version_page.last)
    end

    def send_for_review(version)
      filters = {
        "filter[app]":      app[:id],
        "filter[platform]": :IOS,
        "filter[state]":    "READY_FOR_REVIEW,UNRESOLVED_ISSUES",
      }
      submission = connect.list("/v1/reviewSubmissions", filters).first
      submission ||= connect.create(:reviewSubmissions, { platform: :IOS }, app: link(app))
      add_to_submission(submission, version)
      connect.update(:reviewSubmissions, submission[:id], { submitted: true })
    end

    def add_to_submission(submission, version)
      connect.create(
        :reviewSubmissionItems,
        {},
        reviewSubmission: link(submission),
        appStoreVersion:  link(version),
      )
    rescue Connect::Refused => e
      raise unless e.status == 409
    end
  end
end
