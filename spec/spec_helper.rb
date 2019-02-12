require 'bundler'
Bundler.setup(:default, :development)
require 'rspec/core'
require 'rspec/mocks'

require 'simplecov'
require 'mobystash'

SimpleCov.start do
  add_filter('spec')
end

RSpec.configure do |config|
  # config.fail_fast = true
  config.full_backtrace = true
  config.order = :random

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

require_relative './example_group_methods'
require_relative './example_methods'

RSpec.configure do |config|
  config.include ExampleMethods
  config.extend  ExampleGroupMethods
end
