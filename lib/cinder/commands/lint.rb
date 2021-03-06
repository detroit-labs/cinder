# -*- coding: utf-8 -*-
require 'xcodeproj'
require 'extlib'
require 'cocoapods-core'
require 'rugged'

module Cinder

  class ProvisioningProfile
    attr_reader :distribution
    attr_reader :devices

    def self.from_file f
      begin
        p7 = OpenSSL::PKCS7.new(File.read(f))
        p7.verify([], OpenSSL::X509::Store.new)
        new Plist::parse_xml(p7.data)
      rescue
        new
      end
    end

    def initialize profile = nil
      if profile
        @valid = true
        @devices = []
        if profile['ProvisionsAllDevices']
          @distribution = :enterprise
        elsif profile['ProvisionedDevices']
          @distribution = :ad_hoc
          @devices = profile['ProvisionedDevices']
        else
          # FIXME: could be a developer provisioning profile; need a better check
          @distribution = :app_store
        end
      else
        @valid = false
      end
    end

    def valid?
      @valid == true
    end

    def ad_hoc?
      @distribution == :ad_hoc
    end
  end

  class Linter
    DISTRIBUTION_METHODS = {
      :ad_hoc => 'AdHoc',
      :app_store => 'AppStore',
      :enterprise => 'Enterprise'
    }

    def lint options, args
      abort unless acc = _lint(detect_repository({}))
      say <<-EOS.margin if `git ls-files .cinder`.split($/).empty?

        Additional Steps
        ================

        1. Add ‘deckard’ group to #{acc[:repo_company]}/#{acc[:repo_name]} in GitHub

        2. Tell Hubot to set it up in Janky

                @bot ci setup #{acc[:repo_company]}/#{acc[:repo_name]}
                @bot ci set room #{acc[:repo_name]} #{acc[:name]}

        3. Create a distribution list named ‘#{acc[:name]}’ in TestFlight

        4. Create `setup` and `build` scripts

                mkdir -p script
                curl -L https://raw.github.com/CinderCI/cinder/exec >script/.cinder-exec
                ( cd script ; \\
                  chmod +x .cinder-exec ; \\
                  ln -s .cinder-exec setup ; \\
                  ln -s .cinder-exec build )

        5. Create `script/cibuild`

                #!/bin/bash
                exec "$(dirname $0)/build" --configuration #{acc[:build_configs].keys.grep(/ad_hoc|enterprise/).sort.first.to_s.camel_case}

        6. Add the following to `.gitignore`

                /.bundle/ruby/
                /Pods/
                /bin/

        7. Add and commit a `.cinder` file to repository to turn off this message

        EOS
    end

    def _lint acc = {}
      acc &&=  detect_projects               acc
      acc &&=  detect_workspaces             acc
      acc &&=  determine_name                acc
      acc &&=  check_podfile                 acc
      acc &&=  check_workspace               acc
      acc &&=  check_single_project          acc
      acc &&=  check_multiple_projects       acc
      acc &&=  load_project                  acc
      acc &&=  detect_targets                acc
      acc &&=  check_single_target           acc
      acc &&=  check_multiple_targets        acc
      acc &&=  detect_build_configs          acc
      acc &&=  check_app_store_config        acc
      acc &&=  check_testing_configs         acc
      acc &&=  detect_provisioning_profiles  acc
      acc &&=  check_provisioning_profiles   acc
      acc &&=  check_scheme                  acc

      say_ok 'OK to go' if acc
      acc
    end

    private

    def detect_repository acc
      begin
        path = Rugged::Repository.discover
      rescue
        say_error "Must be in a git repository" and return nil
      end
      acc[:repo] = repo = Rugged::Repository.new path
      acc[:root] = root = File.expand_path '..', repo.path

      say_error "Must be at the root of the project at `#{root}'" and return nil unless root == Dir.getwd
      remotes = `git remote -v`.split("\n")
      # TODO: switch back to using rugged once 0.17.0 is released on rubygems
      upstream = remotes.grep(/upstream/).first
      upstream ||= remotes.grep(/origin/).first
      if upstream.split[1] =~ %r{github.com[:\/]([\w-]+)\/([\w-]+)(.git)?}
        acc[:repo_company], acc[:repo_name] = $1, $2
      end
      say_error "Must have `upstream' or `origin' remote on GitHub" and return nil unless acc[:repo_name]
      acc
    end

    def detect_projects acc
      acc[:projects] = projects = Dir["*.xcodeproj"].map {|f| File.basename(f)}.grep(/^(.*)\.xcodeproj$/){$1}
      say_error "No Xcode project found" and return nil if projects.empty?
      acc
    end

    def detect_workspaces acc
      acc[:workspaces] = Dir["*.xcworkspace"].map {|f| File.basename(f)}.grep(/^(.*)\.xcworkspace$/){$1}
      acc
    end

    def determine_name acc
      if acc[:workspaces].length == 1
        acc[:name] = acc[:workspaces].first
      elsif acc[:projects].length == 1
        acc[:name] = acc[:projects].first
      end
      acc
    end

    def check_podfile acc
      result = acc
      file = Dir['Podfile'].first
      say_error "No CocoaPods Podfile found" and return nil unless file
      podfile = Pod::Podfile.from_file file
      target = podfile.root_target_definitions.first
      platform = target.platform.name if target.platform
      say_error 'CocoaPods platform must be iOS' and result = nil unless platform == :ios
      say_error 'Must have at least one CocoaPods dependency' and result = nil if target.dependencies.empty?
      result
    end

    def check_workspace acc
      workspaces = Dir["*.xcworkspace"].map {|f| File.basename(f)}.grep(/^(.*)\.xcworkspace$/){$1}
      say_error "No Xcode workspace found" and return nil if workspaces.empty?
      say_error "There can be only one Xcode workspace" and return nil if workspaces.length > 1
      acc[:workspace] = workspace = workspaces.first
      say_error "Workspace name `#{workspace}' must not contain whitespace" and return nil if workspace =~ /\s/
      say_warning "Workspace name `#{workspace}' should be CamelCase" unless workspace =~ /^[[:upper:]]\S*(?:[[:upper:]]\s*)*$/
      acc
    end

    def check_single_project acc
      return acc if acc[:projects].length > 1

      acc[:project] = acc[:projects].find { |p| p == acc[:workspace] }
      say_error "Xcode project name `#{acc[:projects].first}' must match workspace name `#{acc[:workspace]}'" and return nil unless acc[:project]
      acc
    end

    def check_multiple_projects acc
      return acc if acc[:projects].length == 1

      acc[:project] = acc[:projects].find { |p| p == acc[:workspace] }
      say_error "One Xcode project name must match workspace name `#{acc[:workspace]}'" and return nil unless acc[:project]
      acc
    end

    def load_project acc
      acc[:xcodeproj] = Xcodeproj::Project.new "#{acc[:project]}.xcodeproj"
      acc
    end

    def detect_targets acc
      acc[:targets] = acc[:xcodeproj].targets
      say_error "Xcode project must have at least one target" and return nil if acc[:targets].empty?
      acc
    end

    def check_single_target acc
      return acc if acc[:targets].length > 1

      acc[:target] = target = acc[:targets].first
      say_error "Target name `#{target.name}' must match workspace name `#{acc[:workspace]}'" and return nil unless target.name == acc[:workspace]
      acc
    end

    def check_multiple_targets acc
      return acc if acc[:targets].length == 1

      acc[:target] = acc[:targets].find { |t| t.name == acc[:workspace] }
      say_error "One Xcode target name must match workspace name `#{acc[:workspace]}'" and return nil unless acc[:target]
      acc
    end

    def detect_build_configs acc
      a = acc[:xcodeproj].build_configurations
      acc[:build_configs] = a.find_all { |c| c.name =~ /^(?:AdHoc|AppStore|Enterprise)$/ }.each_with_object({}) { |c,h| h[c.name.snake_case.to_sym] = c }
      acc
    end

    def check_testing_configs acc
      configs = acc[:build_configs].find_all { |k,v| k == :ad_hoc || k == :enterprise }
      say_error "Must have `AdHoc', `Enterprise', or both build configurations" and return nil if configs.empty?
      acc
    end

    def check_app_store_config acc
      say_warning "Should have `AppStore' build configuration" unless acc[:build_configs][:app_store]
      acc
    end

    def detect_provisioning_profiles acc
      a = Dir['*.mobileprovision'].grep(/^(ad_hoc|app_store|enterprise)\./){$1.to_sym}
      acc[:provisioning_profiles] = a.each_with_object({}) { |p,h| h[p] = "#{p}.mobileprovision" }
      acc
    end

    def check_provisioning_profiles acc
      result = acc

      acc[:build_configs].each do |name, config|
        file = acc[:provisioning_profiles][name]
        if file
          profile = ProvisioningProfile.from_file file
          if profile.valid?
            say_error "`#{file}' appears to be an #{DISTRIBUTION_METHODS[profile.distribution]} provisioning profile" and result = nil unless name == profile.distribution
            say_error "AdHoc provisioning must have at least 1 device provisioned" and result = nil if profile.ad_hoc? && profile.devices.empty?
          else
            say_error "Invalid provisioning profile `#{file}'" and result = nil
          end
        else
          say_error "`#{config.name}' build configuration must have an `#{name}.mobileprovision' in project root" and result = nil
        end
      end
      result
    end

    def check_scheme acc
      schemes = Dir["#{acc[:name]}.xcodeproj/xcshareddata/xcschemes/#{acc[:name]}.xcscheme"].grep(/^(.*)\.xcscheme$/){$1}
      say_error "Must have a shared Xcode scheme named `#{acc[:name]}'" and return nil if schemes.empty?
      acc
    end
  end

  command :lint do |c|
    c.syntax = 'cinder lint'
    c.summary = 'Check for CI problems'
    c.description = 'Report if your project is missing or deviating from Cinder conventions.'
    c.action Linter, :lint
  end
end
