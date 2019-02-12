# coding: utf-8
# frozen_string_literal: true

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "mobystash"
  spec.version       = "0.0.1"
  spec.authors       = ["Matt Palmer"]
  spec.email         = ["matt@discourse.org"]
  spec.description   = %q{Log aggregator for docker container}
  spec.summary       = %q{Ships logs for docker containers to logstash}
  spec.homepage      = "https://github.com/discourse/mobystash"
  spec.license       = "MIT"

  spec.files         = Dir["README.md", "CHANGELOG.md", "LICENSE.txt", "lib/**/*"]

  spec.required_ruby_version = ">= 2.3.0"
end
