require_relative "build"

module AppStore
  # bin/testflight: a build to the internal testers. Makes and uploads one
  # (or sends on the newest one already there), waits for Apple's processing,
  # notes what to test, hands it to the internal group and adds testers.
  class TestFlight < Flow
    # Internal testers have to be App Store Connect users with one of these roles.
    TESTER_ROLES = %w[ACCOUNT_HOLDER ADMIN APP_MANAGER DEVELOPER MARKETING].freeze
    # What someone invited only to test is made: Developer, seeing this app alone.
    INVITED_ROLE = "DEVELOPER".freeze
    TESTFLIGHT_APP = "https://apps.apple.com/app/testflight/id899247664".freeze
    # How recent the newest build is for sending it on to be the suggestion.
    FRESH = 6 * 3600

    def run
      title("#{config.name} to TestFlight")
      builder = Build.new(self)
      build = waiting_build(builder)
      build ||= builder.find(builder.make, marketing_version)
      number = build&.dig(:attributes, :version) || settings[:last_build]
      version = build ? version_of(build) : marketing_version
      build = builder.processed(number, version)
      step("Build #{version} (#{number})")
      no_encryption(build)
      what_to_test(build)
      group = internal_group
      hand_over(build, group)
      testers(group)
      finish(version, number)
    end

    private

    def link(...) = Connect.link(...)

    # The newest build, when the person would rather send it than make another.
    def waiting_build(builder)
      newest = builder.recent.first
      return if newest.nil? || newest.dig(:attributes, :expired)

      attributes = newest[:attributes]
      state = attributes[:processingState].downcase.tr("_", " ")
      fresh = Time.now - Time.parse(attributes[:uploadedDate]) < FRESH
      step("Newest build")
      uploaded = ago(attributes[:uploadedDate])
      say("#{version_of(newest)} (#{attributes[:version]}), uploaded #{uploaded}, #{state}")
      newest if yes?("Send this one rather than making a new build?", default: fresh)
    end

    def version_of(build)
      connect.record("/v1/builds/#{build[:id]}/preReleaseVersion")&.dig(:attributes, :version)
    end

    # Info.plist says so already; a build uploaded before it did still asks.
    def no_encryption(build)
      return unless build.dig(:attributes, :usesNonExemptEncryption).nil?

      connect.update(:builds, build[:id], { usesNonExemptEncryption: false })
      done("Export compliance: no encryption beyond Apple's own")
    end

    def what_to_test(build)
      notes = connect.list("/v1/builds/#{build[:id]}/betaBuildLocalizations")
      note = notes.find { |found| found.dig(:attributes, :locale) == "en-US" } || notes.first
      say("Testers see this note with the build in the TestFlight app, under What to Test.")
      suggested = note&.dig(:attributes, :whatsNew) || changes_since(:tested_through)
      suggested ||= config.first_note
      text = ask("What to test", default: suggested)
      if note
        connect.update(:betaBuildLocalizations, note[:id], { whatsNew: text })
      else
        attributes = { locale: "en-US", whatsNew: text }
        connect.create(:betaBuildLocalizations, attributes, build: link(build))
      end
      note_changes(:tested_through)
      done("What to test noted")
    end

    def internal_group
      loop do
        groups = connect.list("/v1/apps/#{app[:id]}/betaGroups")
        found = groups.find { |group| group.dig(:attributes, :isInternalGroup) }
        return found if found

        begin
          return create_group
        rescue Connect::Refused => e
          warn("Apple wouldn't make the tester group from here: #{e.problems.first}")
          pause(
            [
              "In the left column, click the + beside Internal Testing.",
              "Name it #{config.group}, tick Enable automatic distribution, and click Create.",
            ],
            page: website("TestFlight", "testflight/ios"),
          )
        end
      end
    end

    def create_group
      attributes = { name: config.group, isInternalGroup: true, hasAccessToAllBuilds: true }
      created = connect.create(:betaGroups, attributes, app: link(app))
      done("Internal group #{config.group} made; every new build reaches it")
      created
    end

    def hand_over(build, group)
      name = group.dig(:attributes, :name)
      return done("#{name} gets every build") if group.dig(:attributes, :hasAccessToAllBuilds)

      connect.post("/v1/betaGroups/#{group[:id]}/relationships/builds", [link(build)])
      done("Given to #{name}")
    end

    # Adds the team's users who are not testers yet, then invites anyone else.
    def testers(group)
      step("Testers")
      testing = connect.list("/v1/betaGroups/#{group[:id]}/betaTesters")
      testing.each { |tester| done(person(tester[:attributes])) }
      emails = testing.map { |tester| tester.dig(:attributes, :email).to_s.downcase }
      users = connect.list("/v1/users").select { |user|
        Array(user.dig(:attributes, :roles)).intersect?(TESTER_ROLES) &&
          !emails.include?(user.dig(:attributes, :username).to_s.downcase)
      }
      users.each do |user|
        add_tester(group, user[:attributes]) if yes?("Add #{person(user[:attributes])}?")
      end
      connect.list("/v1/userInvitations").each do |invited|
        warn("#{person(invited[:attributes])} hasn't accepted yet; run this again after they do")
      end
      invite_more
    end

    def add_tester(group, user)
      attributes = {
        email:     user[:username],
        firstName: user[:firstName],
        lastName:  user[:lastName],
      }
      connect.create(:betaTesters, attributes, betaGroups: [link(group)])
      done("Added #{person(user)}")
    end

    # Testers have to be on the team first: invited, then added once they accept.
    def invite_more
      loop do
        email = ask("Invite someone to test (email, Enter to finish)", required: false)
        break if email.empty?

        attributes = {
          email:          email,
          firstName:      ask("First name"),
          lastName:       ask("Last name"),
          roles:          [INVITED_ROLE],
          allAppsVisible: false,
        }
        connect.create(:userInvitations, attributes, visibleApps: [link(app)])
        done("Invited #{email}. Once they accept Apple's email, run this again to add them.")
      end
    end

    def person(attributes)
      name = [attributes[:firstName], attributes[:lastName]].compact.join(" ")
      "#{name} (#{attributes[:email] || attributes[:username]})"
    end

    def finish(version, number)
      step("Done")
      done("#{version} (#{number}) is on TestFlight")
      say("Testers install TestFlight, then open Apple's email or find #{config.name} in it:")
      say(TESTFLIGHT_APP)
      say("The build: #{app_link("testflight/ios")}")
    end
  end
end
