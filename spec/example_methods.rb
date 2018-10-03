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
end
