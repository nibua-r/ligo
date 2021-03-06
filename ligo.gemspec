# -*- encoding: utf-8 -*-

require File.expand_path('../lib/ligo/version', __FILE__)
require 'date'

Gem::Specification.new do |gem|
  gem.name          = 'ligo'
  gem.version       = Ligo::VERSION
  gem.authors       = ['Renaud Aubin']
  gem.date          = Date.today
  gem.summary       = %q{A ruby utility to create virtual accessories able to communicate with Android devices.}
  gem.description   = %q{Ligo: virtual accessories for Android}
  gem.license       = 'Apache-2.0'
  gem.authors       = ['Renaud AUBIN']
  gem.email         = 'root@renaud.io'
  gem.homepage      = 'https://github.com/nibua-r/ligo#readme'

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ['lib']

  gem.add_runtime_dependency 'libusb', '~> 0.3', '>= 0.3.4'

  gem.add_development_dependency 'rspec', '~> 2.13'
  gem.add_development_dependency 'rubygems-tasks', '~> 0.2.4'
  gem.add_development_dependency 'yard', '~> 0.8.7.2'
  gem.add_development_dependency 'yardstick', '~> 0.9.5'
  gem.add_development_dependency 'pry', '~> 0.9.12'
end
