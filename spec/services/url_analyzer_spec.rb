RSpec.describe UrlAnalyzer do
  include ActiveJob::TestHelper

  subject { described_class.new(url) }

  let(:url) { "github.com" }

  def pretty_hash(obj)
    return obj if obj.is_a?(::String)

    ::CodeRay.scan(obj, :ruby).terminal.gsub(
      /\e\[36m:(\w+)\e\[0m=>/i, ("\e[36m" + '\1: ' + "\e[0m") # hashrocket(sym) to colon(sym)
    ).gsub(
      /\e\[0m=>/, "\e[0m: " # all hashrockets to colons
    )
  end

  describe "#analyze" do
    context "localhost" do
      let(:url) { "localhost" }

      specify {
        expect(subject.analyze).to eq({
          origin:    "localhost",
          site:      "localhost",
          protocol:  nil,
          scheme:    nil,
          hostname:  "localhost",
          subdomain: nil,
          domain:    "localhost",
          tld:       nil,
          port:      nil,
          pathname:  nil,
          filename:  nil,
          search:    nil,
          query:     nil,
          hash:      nil,
          fragment:  nil,
        })
      }
    end

    context "local with params" do
      let(:url) { "localhost:3000/orgs/1234/companies/33231/users/42?foo=bar" }

      specify {
        expect(subject.analyze).to eq({
          origin:    "localhost:3000",
          site:      "localhost",
          protocol:  nil,
          scheme:    nil,
          hostname:  "localhost",
          subdomain: nil,
          domain:    "localhost",
          tld:       nil,
          port:      "3000",
          pathname:  "/orgs/1234/companies/33231/users/42",
          filename:  "42",
          search:    "?foo=bar",
          query:     "foo=bar",
          hash:      nil,
          fragment:  nil,
        })
      }

      specify {
        expect(subject.path_param(:orgs)).to eq("1234")
        expect(subject.path_param(:companies)).to eq("33231")
        expect(subject.path_param(:users)).to eq("42")
      }
    end

    context "complex site example" do
      let(:url) { "http://example.com?user[name]=John&user[age]=30&products[0][name]=Book&products[0][price]=12.99&products[1][name]=Pen&products[1][price]=1.49" }

      specify {
        expect(subject.analyze).to eq({
          origin:    "http://example.com",
          site:      "http://example.com",
          protocol:  "http:",
          scheme:    "http",
          hostname:  "example.com",
          subdomain: nil,
          domain:    "example",
          tld:       "com",
          port:      nil,
          pathname:  nil,
          filename:  nil,
          search:    "?user[name]=John&user[age]=30&products[0][name]=Book&products[0][price]=12.99&products[1][name]=Pen&products[1][price]=1.49",
          query:     "user[name]=John&user[age]=30&products[0][name]=Book&products[0][price]=12.99&products[1][name]=Pen&products[1][price]=1.49",
          hash:      nil,
          fragment:  nil,
        })
      }

      specify {
        expect(subject.params.deep_symbolize_keys).to eq({
          products: {
            "0": {
              name: "Book", price: "12.99"
            },
            "1": {
              name: "Pen", price: "1.49"
            },
          },
          user:     {
            age: "30", name: "John"
          },
        })
      }
    end

    context "complex site example" do
      let(:url) { "http://example.com?user[name]=John&user[age]=30&products[][name]=Book&products[][price]=12.99&products[][name]=Pen&products[][price]=1.49" }

      specify {
        expect(subject.analyze).to eq({
          origin:    "http://example.com",
          site:      "http://example.com",
          protocol:  "http:",
          scheme:    "http",
          hostname:  "example.com",
          subdomain: nil,
          domain:    "example",
          tld:       "com",
          port:      nil,
          pathname:  nil,
          filename:  nil,
          search:    "?user[name]=John&user[age]=30&products[][name]=Book&products[][price]=12.99&products[][name]=Pen&products[][price]=1.49",
          query:     "user[name]=John&user[age]=30&products[][name]=Book&products[][price]=12.99&products[][name]=Pen&products[][price]=1.49",
          hash:      nil,
          fragment:  nil,
        })
      }

      specify {
        expect(subject.params.deep_symbolize_keys).to eq({
          products: [
            { name: "Book", price: "12.99" },
            { name: "Pen", price: "1.49" },
          ],
          user:     {
            age: "30", name: "John"
          },
        })
      }
    end

    context "basic_domain" do
      let(:url) { "github.com" }

      specify {
        expect(subject.analyze).to eq({
          origin:    "github.com",
          site:      "github.com",
          protocol:  nil,
          scheme:    nil,
          hostname:  "github.com",
          subdomain: nil,
          domain:    "github",
          tld:       "com",
          port:      nil,
          pathname:  nil,
          filename:  nil,
          search:    nil,
          query:     nil,
          hash:      nil,
          fragment:  nil,
        })
      }
    end

    context "subdomain_domain" do
      let(:url) { "cats.github.com" }

      specify {
        expect(subject.analyze).to eq({
          origin:    "cats.github.com",
          site:      "cats.github.com",
          protocol:  nil,
          scheme:    nil,
          hostname:  "cats.github.com",
          subdomain: "cats",
          domain:    "github",
          tld:       "com",
          port:      nil,
          pathname:  nil,
          filename:  nil,
          search:    nil,
          query:     nil,
          hash:      nil,
          fragment:  nil,
        })
      }
    end

    context "uk_tld" do
      let(:url) { "github.org.au" }

      specify {
        expect(subject.analyze).to eq({
          origin:    "github.org.au",
          site:      "github.org.au",
          protocol:  nil,
          scheme:    nil,
          hostname:  "github.org.au",
          subdomain: nil,
          domain:    "github",
          tld:       "org.au",
          port:      nil,
          pathname:  nil,
          filename:  nil,
          search:    nil,
          query:     nil,
          hash:      nil,
          fragment:  nil,
        })
      }
    end

    context "subdomain_uk_tld" do
      let(:url) { "helix.clip.orca.co.uk" }

      specify {
        expect(subject.analyze).to eq({
          origin:    "helix.clip.orca.co.uk",
          site:      "helix.clip.orca.co.uk",
          protocol:  nil,
          scheme:    nil,
          hostname:  "helix.clip.orca.co.uk",
          subdomain: "helix.clip",
          domain:    "orca",
          tld:       "co.uk",
          port:      nil,
          pathname:  nil,
          filename:  nil,
          search:    nil,
          query:     nil,
          hash:      nil,
          fragment:  nil,
        })
      }
    end
  end
end
