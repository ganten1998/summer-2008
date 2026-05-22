# -*- encoding: utf-8 -*-
# stub: wayback_machine_downloader 2.3.1 ruby lib

Gem::Specification.new do |s|
  s.name = "wayback_machine_downloader".freeze
  s.version = "2.3.1"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["hartator".freeze]
  s.date = "2021-09-04"
  s.description = "Download an entire website from the Wayback Machine. Wayback Machine by Internet Archive (archive.org) is an awesome tool to view any website at any point of time but lacks an export feature. Wayback Machine Downloader brings exactly this.".freeze
  s.email = "hartator@gmail.com".freeze
  s.executables = ["wayback_machine_downloader".freeze]
  s.files = ["bin/wayback_machine_downloader".freeze]
  s.homepage = "https://github.com/hartator/wayback-machine-downloader".freeze
  s.licenses = ["MIT".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 1.9.2".freeze)
  s.rubygems_version = "3.0.3.1".freeze
  s.summary = "Download an entire website from the Wayback Machine.".freeze

  s.installed_by_version = "3.0.3.1" if s.respond_to? :installed_by_version

  if s.respond_to? :specification_version then
    s.specification_version = 4

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_development_dependency(%q<rake>.freeze, ["~> 10.2"])
      s.add_development_dependency(%q<minitest>.freeze, ["~> 5.2"])
    else
      s.add_dependency(%q<rake>.freeze, ["~> 10.2"])
      s.add_dependency(%q<minitest>.freeze, ["~> 5.2"])
    end
  else
    s.add_dependency(%q<rake>.freeze, ["~> 10.2"])
    s.add_dependency(%q<minitest>.freeze, ["~> 5.2"])
  end
end
