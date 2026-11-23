require "tmpdir"
require_relative "../../ios/buddy/app_store"
require_relative "../../ios/script/app_store/testflight"
require_relative "../../ios/script/app_store/release"

RSpec.describe AppStore do
  # App Store Connect as the scripts see it: canned answers by path, every write kept.
  let(:fake_connect) {
    Class.new {
      attr_reader :writes

      def initialize(answers)
        @answers = answers
        @writes = []
      end

      def list(path, _params={}) = @answers.fetch(path, [])
      def get(path, _params={}) = { data: @answers.fetch(path, []) }
      def record(path, _params={}) = @answers[path]

      def create(type, attributes={}, relationships={})
        @writes << [:create, type, attributes, relationships]
        { id: "new-#{type}", type: type.to_s, attributes: attributes }
      end

      def update(type, id, attributes={}, relationships={})
        @writes << [:update, type, id, attributes, relationships]
        { id: id, type: type.to_s, attributes: attributes }
      end

      def post(path, data)
        @writes << [:post, path, data]
        {}
      end
    }
  }
  let(:home) { Dir.mktmpdir("app-store") }
  let(:config) { AppStore::BUDDY }
  let(:app) { { id: "app1", type: "apps", attributes: { bundleId: "com.ardesian.buddy" } } }
  let(:build) {
    attributes = {
      version:                 "7",
      processingState:         "VALID",
      uploadedDate:            (Time.now.utc - 600).iso8601,
      expired:                 false,
      usesNonExemptEncryption: nil,
    }
    { id: "build7", type: "builds", attributes: attributes }
  }

  before {
    stub_const("AppStore::Flow::SETTINGS_DIR", home)
    stub_const("AppStore::Flow::KEYS", File.join(home, "private_keys"))
  }

  after { FileUtils.rm_rf(home) }

  def run(flow, connect, answers)
    flow.instance_variable_set(:@connect, connect)
    flow.instance_variable_set(:@app, app)
    talk(answers) { flow.run }
  end

  def talk(answers)
    $stdin = StringIO.new("#{answers.join("\n")}\n")
    $stdout = StringIO.new
    yield
  ensure
    $stdin = STDIN
    $stdout = STDOUT
  end

  def to(type, id) = { type: type, id: id }

  def user(email, first, last, role)
    { attributes: { username: email, firstName: first, lastName: last, roles: [role] } }
  end

  def json_part(part) = JSON.parse(Base64.urlsafe_decode64(part))

  def write_key(id)
    key = OpenSSL::PKey::EC.generate("prime256v1")
    FileUtils.mkdir_p(AppStore::Flow::KEYS)
    path = File.join(AppStore::Flow::KEYS, "AuthKey_#{id}.p8")
    File.write(path, key.to_pem)
    [key, path]
  end

  it "signs its token with the API key the way Apple checks it" do
    key, path = write_key("ABC123")
    connect = AppStore::Connect.new(key_id: "ABC123", issuer_id: "issuer", key_path: path)

    header, claims, signature = connect.send(:token).split(".")
    raw = Base64.urlsafe_decode64(signature)
    numbers = [raw[0, 32], raw[32, 32]].map { |half|
      OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(half, 2))
    }
    der = OpenSSL::ASN1::Sequence.new(numbers).to_der

    expect(key.verify(OpenSSL::Digest.new("SHA256"), der, "#{header}.#{claims}")).to be(true)
    expect(json_part(header)).to include("alg" => "ES256", "kid" => "ABC123")
    expect(json_part(claims)).to include("iss" => "issuer", "aud" => "appstoreconnect-v1")
  end

  it "takes the team key another app on this Mac already set up, rather than making one" do
    write_key("SHARED1")
    File.write(File.join(home, "astra.json"), JSON.generate(key_id: "SHARED1", issuer_id: "iss"))
    flow = AppStore::TestFlight.new(config)

    connect = talk(["y"]) { flow.connect }

    expect(connect).to be_a(AppStore::Connect)
    saved = JSON.parse(File.read(File.join(home, "buddy.json")))
    expect(saved).to include("key_id" => "SHARED1", "issuer_id" => "iss")
  end

  it "signs with the team a Local xcconfig names over the shared one" do
    dir = File.join(home, "app")
    FileUtils.mkdir_p(File.join(dir, "Config"))
    File.write(File.join(dir, "Config/Shared.xcconfig"), "DEVELOPMENT_TEAM = AAAAA11111\n")
    File.write(File.join(dir, "Config/Local.xcconfig"), "DEVELOPMENT_TEAM = BBBBB22222\n")
    local = config.dup
    local.instance_variable_set(:@dir, dir)

    expect(AppStore::TestFlight.new(local).team).to eq("BBBBB22222")
  end

  it "sends the newest build to a new internal group with what to test, adding the team" do
    connect = fake_connect.new(
      "/v1/builds"                          => [build],
      "/v1/builds/build7/preReleaseVersion" => { attributes: { version: "1.0" } },
      "/v1/users"                           => [
        user("pat@example.com", "Pat", "Lee", "ADMIN"),
        user("sam@example.com", "Sam", "Fox", "SALES"),
      ],
    )

    run(AppStore::TestFlight.new(config), connect, ["y", "Try the widget", "y", ""])

    group = { name: "Buddy team", isInternalGroup: true, hasAccessToAllBuilds: true }
    tester = { email: "pat@example.com", firstName: "Pat", lastName: "Lee" }
    expect(connect.writes).to contain_exactly(
      [:update, :builds, "build7", { usesNonExemptEncryption: false }, {}],
      [
        :create,
        :betaBuildLocalizations,
        { locale: "en-US", whatsNew: "Try the widget" },
        { build: to("builds", "build7") },
      ],
      [:create, :betaGroups, group, { app: to("apps", "app1") }],
      [:create, :betaTesters, tester, { betaGroups: [to("betaGroups", "new-betaGroups")] }],
    )
  end

  it "fills in a first version's listing and review details from the answers and submits it" do
    File.write(File.join(home, "buddy.json"), JSON.generate(done: %w[app_privacy pricing unlisted]))
    version = { id: "v1", type: "appStoreVersions", attributes: { versionString: "1.0" } }
    version[:attributes][:appVersionState] = "PREPARE_FOR_SUBMISSION"
    english = ->(id) { [{ id: id, attributes: { locale: "en-US" } }] }
    info = [{ id: "info1", attributes: { state: "PREPARE_FOR_SUBMISSION" } }]
    rating = { attributes: { gambling: false } }
    shots = [{ id: "set1", attributes: { screenshotDisplayType: "APP_IPHONE_67" } }]
    connect = fake_connect.new(
      "/v1/apps/app1/appStoreVersions"                          => [version],
      "/v1/builds"                                              => [build],
      "/v1/appStoreVersions/v1/appStoreVersionLocalizations"    => english["loc1"],
      "/v1/apps/app1/appInfos"                                  => info,
      "/v1/appInfos/info1/appInfoLocalizations"                 => english["infoloc1"],
      "/v1/appInfos/info1/ageRatingDeclaration"                 => rating,
      "/v1/appStoreVersionLocalizations/loc1/appScreenshotSets" => shots,
      "/v1/appScreenshotSets/set1/appScreenshots"               => [{ id: "shot1" }],
    )
    review = ["Pat", "Lee", "+1 555 555 5555", "pat@example.com", "demo@example.com", "secret", ""]

    run(AppStore::Release.new(config), connect, ["1.0", "y", "", "", "", "", "", "", *review, "", "y"])

    expect(connect.writes).to include(
      [:update, :appStoreVersions, "v1", {}, { build: to("builds", "build7") }],
      [
        :update,
        :appInfoLocalizations,
        "infoloc1",
        { privacyPolicyUrl: "https://ardesian.com/privacy-policy" },
        {},
      ],
      [:update, :appInfos, "info1", {}, { primaryCategory: to(:appCategories, "PRODUCTIVITY") }],
      [:update, :apps, "app1", { contentRightsDeclaration: :DOES_NOT_USE_THIRD_PARTY_CONTENT }, {}],
      [:update, :reviewSubmissions, "new-reviewSubmissions", { submitted: true }, {}],
    )
    listing = connect.writes.find { |write| write[1] == :appStoreVersionLocalizations }
    expect(listing[3]).to include(description: config.description, keywords: config.keywords)
    details = connect.writes.find { |write| write[1] == :appStoreReviewDetails }[2]
    expect(details).to include(contactEmail: "pat@example.com", demoAccountPassword: "secret")
    expect(details).to include(demoAccountRequired: true)
    expect(details[:notes]).to eq(config.review_notes)
  end
end
