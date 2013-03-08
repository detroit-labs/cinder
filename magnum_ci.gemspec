# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$:.unshift(lib) unless $:.include?(lib)

require 'magnum_ci/version'

Gem::Specification.new do |s|
  s.name          = "magnum_ci"
  s.version       = MagnumCI::VERSION
  s.authors       = ["Tim Taylor"]
  s.email         = ["tim@detroitlabs.com"]
  s.description   = "Continuous Delivery for iOS Apps"
  s.summary       = "Magnum CI"
  s.homepage      = ""
  s.license       = "MIT"

  s.add_dependency "commander", "~> 4.1.3"
  s.add_dependency "extlib", "~> 0.9.16"
  s.add_dependency "plist", "~> 3.1.0"
  s.add_dependency "dotenv", "~> 0.5.0"
  s.add_dependency "cocoapods", "~> 0.16.0"
  s.add_dependency "shenzhen", "~> 0.3.0"

  s.add_development_dependency "bundler", "~> 1.3"
  s.add_development_dependency "rake"

  s.files         = `git ls-files`.split($/)
  s.executables   = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.test_files    = s.files.grep(%r{^(test|spec|features)/})
  s.require_paths = ["lib"]
end
