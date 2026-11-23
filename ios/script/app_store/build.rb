require "open3"
require_relative "flow"

module AppStore
  # Making a build and getting it through Apple's processing: generate the
  # project, archive it, upload it, and wait until App Store Connect has
  # checked it. The build number is never kept in the project: each upload
  # takes the next one after every build Apple or this Mac knows of.
  class Build
    include Wizard

    # How often and how long to look for the uploaded build being processed.
    LOOK_EVERY = 30
    LOOK_FOR = 90 * 60
    FINISHED = %w[VALID FAILED INVALID].freeze

    def initialize(flow)
      @flow = flow
      @config = flow.config
    end

    def builds = File.join(@config.dir, "build")

    # Checks the tree, then archives and uploads; the new build's number.
    def make
      version = @flow.marketing_version
      number = next_number
      step("Build #{version} (#{number})")
      check_tree
      run("Generating the project", "xcodegen", "generate", log: "xcodegen")
      archive = File.join(builds, "archives", "#{@config.name}-#{version}-#{number}.xcarchive")
      run(
        "Archiving (a few minutes)",
        "xcodebuild", "archive",
        "-project", @config.project, "-scheme", @config.scheme, "-configuration", "Release",
        "-destination", "generic/platform=iOS", "-archivePath", archive,
        *signing, "CURRENT_PROJECT_VERSION=#{number}",
        log: "archive-#{number}"
      )
      # Taken once archived, so an upload Apple turns away for its number isn't retried with it.
      @flow.save(last_build: number)
      run(
        "Uploading to App Store Connect",
        "xcodebuild", "-exportArchive", "-archivePath", archive,
        "-exportOptionsPlist", export_options, "-exportPath", File.join(builds, "export"),
        *signing,
        log: "upload-#{number}"
      )
      number
    end

    # The build once Apple has processed it.
    def processed(number, version)
      step("Waiting for Apple to process #{version} (#{number})")
      say("Usually 5 to 30 minutes. Stopping here loses nothing: the build carries on at Apple.")
      deadline = Time.now + LOOK_FOR
      seen = nil
      loop do
        build = find(number, version)
        state = build&.dig(:attributes, :processingState) || "UPLOADED"
        say("#{Time.now.strftime("%-I:%M")} #{state.downcase.tr("_", " ")}") if state != seen
        seen = state
        return build if state == "VALID"
        if FINISHED.include?(state)
          raise Error, "Apple marked the build #{state.downcase}; it emails the reason."
        end
        raise Error, "Not processed after #{LOOK_FOR / 60} minutes." if Time.now > deadline

        sleep(LOOK_EVERY)
      end
    end

    def find(number, version)
      params = {
        "filter[app]":                       @flow.app[:id],
        "filter[version]":                   number.to_s,
        "filter[preReleaseVersion.version]": version,
      }
      @flow.connect.list("/v1/builds", params).first
    end

    # The newest builds on App Store Connect, newest first.
    def recent(params={})
      base = { "filter[app]": @flow.app[:id], sort: "-uploadedDate", limit: 10 }
      Array(@flow.connect.get("/v1/builds", base.merge(params))[:data])
    end

    private

    def next_number
      known = recent.map { |build| build.dig(:attributes, :version).to_i }
      known << @flow.settings[:last_build].to_i
      known.max + 1
    end

    def check_tree
      branch = @flow.git("rev-parse", "--abbrev-ref", "HEAD")
      say("From #{branch} at #{@flow.git("log", "-1", "--format=%h %s")}")
      changed = @flow.git("status", "--short", "--", @config.dir)
      return if changed.empty?

      warn("Uncommitted changes in #{File.basename(@config.dir)}/ go into this build:")
      changed.each_line { |line| say("  #{line.chomp}") }
      raise Interrupt unless yes?("Build with them?")
    end

    # Signs and uploads with the API key, so nothing waits on Xcode's account. The
    # team is named outright, since an xcconfig can leave it blank.
    def signing
      [
        "DEVELOPMENT_TEAM=#{@flow.team}",
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        @flow.key_path,
        "-authenticationKeyID",
        @flow.settings[:key_id],
        "-authenticationKeyIssuerID",
        @flow.settings[:issuer_id],
      ]
    end

    # Uploads straight to App Store Connect, keeping the build number given here.
    def export_options
      path = File.join(builds, "ExportOptions.plist")
      FileUtils.mkdir_p(builds)
      File.write(
        path,
        <<~PLIST,
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>method</key><string>app-store-connect</string>
            <key>destination</key><string>upload</string>
            <key>teamID</key><string>#{@flow.team}</string>
            <key>signingStyle</key><string>automatic</string>
            <key>manageAppVersionAndBuildNumber</key><false/>
            <key>uploadSymbols</key><true/>
          </dict>
          </plist>
        PLIST
      )
      path
    end

    # Runs a tool in the app's folder with its output in build/logs, showing the errors on failure.
    def run(label, *command, log:)
      FileUtils.mkdir_p(File.join(builds, "logs"))
      log_path = File.join(builds, "logs", "#{log}.log")
      started = Time.now
      print("   #{label}... ")
      output, status = Open3.capture2e(*command, chdir: @config.dir)
      File.write(log_path, output)
      if status.success?
        puts(green("done in #{(Time.now - started).round}s"))
        return
      end

      puts
      problems = output.lines.grep(/error:|Error Domain|failed/i).last(15)
      (problems.empty? ? output.lines.last(15) : problems).each { |line| say(line.chomp) }
      raise Error, "#{label} failed. The whole log: #{log_path}"
    end
  end
end
