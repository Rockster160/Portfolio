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

  def image_fixture(path)
    fixture_file_upload(::Rails.root.join("spec/fixtures/#{path}"), "image/png")
  end

  def fixture(path)
    File.read(::Rails.root.join("spec/fixtures/#{path}"))
  end
end
