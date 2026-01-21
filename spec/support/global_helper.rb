module GlobalHelper
  include ActionDispatch::TestProcess

  def condensed(string)
    string.gsub(/\s+/, "")
  end

  def html_fixture(path, raw: false)
    fixture("#{path}.html").then { |html| raw ? html : Nokogiri::HTML(html) }
  end

  def json_fixture(path, symbolize_names: true)
    JSON.parse(fixture("#{path}.json"), symbolize_names: symbolize_names)
  end

  def yaml_fixture(path)
    YAML.safe_load(fixture("#{path}.yaml"))
  end

  def xml_fixture(path)
    ::Nokogiri::XML(fixture("#{path}.xml")).to_xml
  end

  def jil_fixture(path)
    fixture("jil/#{path}.jil")
  end

  def image_fixture(path)
    fixture_file_upload(::Rails.root.join("spec/fixtures/#{path}"), "image/png")
  end

  def fixture(path)
    ::Rails.root.join("spec/fixtures/#{path}").read
  end

  def expect_successful_jil
    if ctx[:error_line].present?
      load("/Users/zoro/.pryrc")
      source_puts [ctx[:error_line], ctx[:error]].compact.join("\n")
    end
    expect([ctx[:error_line], ctx[:error]].compact.join("\n")).to be_blank
  end
end
