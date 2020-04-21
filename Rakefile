exec(*(["bundle", "exec", $PROGRAM_NAME] + ARGV)) if ENV['BUNDLE_GEMFILE'].nil?

task default: :test
task default: :doc_stats

begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts "Run `bundle install` to install missing gems"
  exit e.status_code
end

def git_describe
  @git_describe ||= `git describe --always --dirty`.chomp
end

def version
  build_metadata = git_describe()
  raise RuntimeError.new("Received empty build metadata from 'git describe'") unless build_metadata.length > 0
  "0.0.1-git+#{build_metadata}"
end

def docker_tagify(tag)
  # https://docs.docker.com/engine/reference/commandline/tag/
  tag.tr_s('^A-Za-z0-9_.\-', '-').sub(/^-+/, '')
end

require 'yard'

task :doc_stats do
  sh "yard stats --list-undoc"
end

YARD::Rake::YardocTask.new :doc do |yardoc|
  yardoc.files = %w{lib/**/*.rb - README.md CONTRIBUTING.md CODE_OF_CONDUCT.md}
end

desc "Run guard"
task :guard do
  sh "guard --clear"
end

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new :test do |t|
  t.pattern = "spec/**/*_spec.rb"
end

namespace :docker do
  tag = docker_tagify(version())

  desc "Build a new docker image"
  task :build do
    sh "docker build --pull -t discourse/mobystash --build-arg=http_proxy=#{ENV['http_proxy']} --build-arg=GIT_REVISION=$(git rev-parse HEAD) ."
    sh "docker tag discourse/mobystash discourse/mobystash:#{tag}"
  end

  desc "Publish a new docker image"
  task publish: :build do
    sh "docker push discourse/mobystash:#{tag}"
    sh "docker push discourse/mobystash"
  end
end
