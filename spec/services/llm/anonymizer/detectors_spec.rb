# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR2, step A1: the built-in patterns. Every value is synthetic; secrets are random.
RSpec.describe Llm::Anonymizer::Detectors do
  let(:tokens) { Llm::Anonymizer::Tokens.new }
  let(:counts) { Hash.new(0) }

  def mask(text) = described_class.mask(text, tokens, counts)

  def random_string(length, alphabet = [ *"a".."z", *"A".."Z", *"0".."9" ]) = Array.new(length) { alphabet.sample }.join

  it "redacts secrets as an untyped ⟦SECRET⟧ that isn't in the map" do
    secrets = [
      "sk-#{random_string(40)}", "ghp_#{random_string(36)}", "github_pat_#{random_string(30)}", "xoxb-#{random_string(24)}",
      "AKIA#{random_string(16, [ *"A".."Z", *"0".."9" ])}", "eyJ#{random_string(12)}.#{random_string(20)}.#{random_string(20)}",
      "-----BEGIN PRIVATE KEY-----\n#{random_string(40)}\n-----END PRIVATE KEY-----", "Aa1#{random_string(40)}"
    ]
    secrets.each do |secret|
      text, redacted = mask("key #{secret} end")
      expect(text).to eq("key ⟦SECRET⟧ end"), secret
      expect(redacted).to eq(1)
    end
    expect(mask("password: #{random_string(12)} and api_key=#{random_string(10)}").first).to eq("password: ⟦SECRET⟧ and api_key=⟦SECRET⟧")
    expect(mask("token: sk-#{random_string(30)}")).to eq([ "token: ⟦SECRET⟧", 1 ])
    expect(described_class.hit?("token: ⟦SECRET⟧")).to be(false)
    expect(counts).to be_empty
  end

  it "redacts values behind env-style and compound secret names, and random-looking runs of every common shape" do
    value = random_string(16)
    %w[DB_PASSWORD= POSTGRES_PASSWORD:\  GITHUB_TOKEN= OPENAI_API_KEY= aws_secret_access_key\ =\  STRIPE_SECRET_KEY= SECRET_KEY_BASE=].each do |name|
      expect(mask("#{name}#{value}").first).to eq("#{name}⟦SECRET⟧"), name
    end
    [ random_string(64, [ *"0".."9", *"A".."F" ]), random_string(32, [ *"a".."z", *"0".."9" ]).sub(/\A\D{0,8}/) { |head| head.tr("a-z", "1-9") },
      "#{random_string(20)}/#{random_string(20)}", "#{random_string(20)}-_#{random_string(20)}" ].each do |run|
      expect(mask("key #{run} end").first).to eq("key ⟦SECRET⟧ end"), run
    end

    plain = "tokens = tokenize(x); token_count = 5; secretary: Ada; password=abc; supercalifragilisticexpialidocious_words; " \
            "SomeVeryLongCamelCaseIdentifierName2; b=1-Zq7CanaryWidget-Zq7CanaryWidgets-Zq7Canary"
    expect(mask(plain)).to eq([ plain, 0 ])
  end

  it "masks URLs (git remotes too), e-mails, IPs, private hosts and absolute paths whole" do
    text, = mask("See https://git.zq7canary.example/org/repo.git, git@git.zq7canary.example:org/repo.git, ops@zq7canary.example, " \
                 "10.7.7.7, fd00:7::7, build.zq7canary.internal, /srv/zq7canary/app.rb, ~/zq7/notes.md and C:\\Work\\zq7\\a.txt.")

    expect(text).not_to include("zq7", "10.7", "fd00")
    expect(text.scan(/⟦(\w+)_\h{4}⟧/).flatten).to eq(%w[URL URL EMAIL IP IP HOST PATH PATH PATH])
    expect(mask("ip_10.7.7.7_x and url_https://zq7.example/a").first).not_to include("10.7", "zq7")
    expect(mask("Build.Zq7Canary.INTERNAL and FD00:7::7, not Time.local or Abc::Def").first)
      .to match(/\A⟦HOST_\h{4}⟧ and ⟦IP_\h{4}⟧, not Time\.local or Abc::Def\z/)
  end

  it "masks a Windows home path inside JSON data whole, and finds its owner" do
    json = JSON.generate(path: "C:\\Users\\zq7win\\src\\app.rb")

    expect(described_class.owners(json)).to eq(%w[zq7win])
    expect(mask(json).first).to match(/\A\{"path":"⟦PATH_\h{4}⟧"\}\z/)
  end

  it "leaves method chains, versions, relative paths, times and Ruby constants alone" do
    plain = "Rails.logger.info(user.name) on 1.66.0 and ruby-3.4.12 in lib/gadget/x.rb at 12:30:01 via Foo::Bar and a/b."

    expect(mask(plain)).to eq([ plain, 0 ])
    expect(described_class.hit?(plain)).to be(false)
  end

  it "finds the owners of home-directory paths" do
    expect(described_class.owners("/home/zq7user/a, /Users/zq7mac/b and C:\\Users\\zq7win\\c")).to eq(%w[zq7user zq7mac zq7win])
  end
end
