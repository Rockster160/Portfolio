# The GitHub repos a build can be for. ByteSlime has to be a collaborator on
# each, and each needs the same webhook as Portfolio (FeatureBuilder.github!)
# for its PR's review and merge to reach the build.
#
# Portfolio is the only one with a merge queue and a deploy behind it. A PR
# anywhere else is merged by its owner, and its build is then left to pull on
# the laptop until the laptop's checkout has it (FeatureBuild.to_pull).
#
# A model reads the request and picks one. Anything it says that isn't one of
# these is Portfolio.
module FeatureBuilder
  module Repos
    module_function

    PORTFOLIO = "Rockster160/Portfolio".freeze

    # What each one is, as the model is told it.
    LIST = {
      PORTFOLIO                 => "Portfolio, the Rails app at ardesian.com: Jarvis, Jil, " \
                                   "Buddy and Byte, lists, chores, the dashboard, and the " \
                                   "Feature Builder itself. The default.",
      "Rockster160/hass-config" => "The house's Home Assistant config: Zigbee devices, cameras, " \
                                   "automations and dashboards on the Raspberry Pi.",
      "Rockster160/ParkourUtah" => "The Parkour Utah gym's website (PKUT), a separate Rails app.",
      "Rockster160/slime-civ"   => "Slime Civ, a colony sim game in one HTML file of plain JavaScript.",
    }.freeze

    MODEL = BranchName::MODEL
    MAX_CHARS = 2_000

    # The repo `request` is for, as owner/name.
    def for(request, user:)
      return PORTFOLIO if LIST.one?

      result = ::Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: prompt,
        input:        [{ role: :user, content: [{ type: :input_text, text: request.to_s[0, MAX_CHARS] }] }],
      )
      record_usage(result, user)
      result[:ok] ? match(result[:text]) : PORTFOLIO
    rescue StandardError => e
      Rails.logger.warn("[FeatureBuilder::Repos] #{e.class}: #{e.message}")
      PORTFOLIO
    end

    def prompt
      repos = LIST.map { |repo, about| "- #{short_name(repo)}: #{about}" }
      <<~PROMPT
        You pick which repo a feature request is for. The repos:

        #{repos.join("\n")}

        Reply with the repo's name only. When the request doesn't clearly name
        another one, or could be any of them, reply "#{short_name(PORTFOLIO)}".
      PROMPT
    end

    # The listed repo an answer names, by its name or owner/name.
    def match(text)
      said = text.to_s.lines.first.to_s.strip.delete("`\"'*.").downcase
      LIST.keys.find { |repo| [repo.downcase, short_name(repo).downcase].include?(said) } || PORTFOLIO
    end

    def short_name(repo)
      repo.to_s.split("/").last
    end

    def portfolio?(repo)
      repo.to_s.casecmp?(PORTFOLIO)
    end

    def record_usage(result, user)
      ::BuddyUsage.record!(result, user: user, kind: :build_repo)
    rescue StandardError => e
      Rails.logger.warn("[FeatureBuilder::Repos] usage record failed: #{e.class}: #{e.message}")
    end
  end
end
