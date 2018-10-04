require 'docker-api'
require 'resolv'
require 'yaml'

module ExampleMethods
  def container_fixture(name)
    data = YAML.load_file(File.expand_path("../fixtures/container_data/#{name}.yml", __FILE__))
    Docker::Container.send(:new, Docker::Connection.new("unix:///", {}), data)
  end

  def container_fixtures(*names)
    names.map { |n| container_fixture(n) }
  end

  # Yes, this could be a matcher, but honestly it's just much easier this way
  def expect_log_message(logger, level, progname, message_regex)
    expect(logger).to receive(level.to_sym) do |pn, &msg|
      expect(pn).to eq(progname)
      expect(msg.call).to match(message_regex)
    end
  end
end
