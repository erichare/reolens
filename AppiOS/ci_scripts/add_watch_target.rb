#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the ReolensWatch (watchOS 11) companion target to ReolensiOS.xcodeproj.
#
# Idempotent: re-running detects an existing `ReolensWatch` target and
# bails with a non-zero exit code rather than duplicating entries. Use
# `xcodebuild -project ReolensiOS.xcodeproj -list` to verify.
#
# Pre-reqs:
#   gem install --user-install xcodeproj
#   GEM_HOME pointed at ~/.gem/ruby/<ver>/ (the script does this itself).

require 'rubygems'
gem_paths = Dir.glob(File.expand_path('~/.gem/ruby/*'))
gem_paths.each { |p| $LOAD_PATH.unshift(File.join(p, 'gems', 'xcodeproj-1.27.0', 'lib')) }
gem_paths.each { |p| ENV['GEM_PATH'] = [p, ENV['GEM_PATH']].compact.join(':') }
require 'xcodeproj'

PROJECT_PATH = File.expand_path(File.join(__dir__, '..', 'ReolensiOS.xcodeproj'))
TARGET_NAME  = 'ReolensWatch'
BUNDLE_ID    = 'com.reolens.Reolens.iOS.watchkitapp'
TEAM_ID      = '5M9UT7VQ8Q'
SOURCE_DIR   = 'Watch'  # relative to AppiOS/
WATCH_SDK    = 'watchos'
WATCH_DEPLOYMENT = '11.0'

project = Xcodeproj::Project.open(PROJECT_PATH)

# Idempotency: bail loudly if the target already exists.
if project.targets.any? { |t| t.name == TARGET_NAME }
  warn "Target '#{TARGET_NAME}' already exists in #{PROJECT_PATH}. Aborting to avoid duplication."
  exit 1
end

# --- 1. Create the watchOS application target ----------------------------
# `new_target` defaults to building an iOS application; we override the
# platform settings to watchOS via the build configurations below.
watch_target = project.new_target(
  :application,
  TARGET_NAME,
  :watchos,
  WATCH_DEPLOYMENT,
  nil,
  :swift
)

# --- 2. Wire build settings -----------------------------------------------
watch_target.build_configurations.each do |config|
  bs = config.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER']            = BUNDLE_ID
  bs['PRODUCT_NAME']                          = 'Reolens'
  bs['DEVELOPMENT_TEAM']                      = TEAM_ID
  bs['CODE_SIGN_STYLE']                       = 'Automatic'
  bs['CODE_SIGN_ENTITLEMENTS']                = "#{SOURCE_DIR}/ReolensWatch.entitlements"
  bs['INFOPLIST_FILE']                        = "#{SOURCE_DIR}/Info.plist"
  bs['SDKROOT']                               = WATCH_SDK
  bs['SUPPORTED_PLATFORMS']                   = 'watchos watchsimulator'
  bs['WATCHOS_DEPLOYMENT_TARGET']             = WATCH_DEPLOYMENT
  bs['TARGETED_DEVICE_FAMILY']                = '4'  # Watch
  bs['SWIFT_VERSION']                         = '6.0'
  bs['GENERATE_INFOPLIST_FILE']               = 'NO'
  bs['CURRENT_PROJECT_VERSION']               = '16'
  bs['MARKETING_VERSION']                     = '0.6.6'
  bs['ENABLE_PREVIEWS']                       = 'YES'
  bs['ASSETCATALOG_COMPILER_APPICON_NAME']    = 'AppIcon'
  bs['LD_RUNPATH_SEARCH_PATHS']               = '$(inherited) @executable_path/Frameworks'
  bs['SKIP_INSTALL']                          = 'NO'
end

# --- 3. Add the source group + files --------------------------------------
# Create a `Watch` group at the project root mirroring the on-disk layout.
watch_group = project.main_group.find_subpath(SOURCE_DIR, true)
watch_group.set_source_tree('<group>')
watch_group.set_path(SOURCE_DIR)

# WatchApp.swift goes into the sources build phase.
watch_app_ref = watch_group.new_reference("#{SOURCE_DIR}/WatchApp.swift")
watch_app_ref.last_known_file_type = 'sourcecode.swift'
watch_app_ref.set_source_tree('SOURCE_ROOT')
watch_app_ref.set_path('Watch/WatchApp.swift')
watch_target.add_file_references([watch_app_ref])

# Info.plist and entitlements get file references but no build-phase
# attachment — they're referenced via INFOPLIST_FILE and
# CODE_SIGN_ENTITLEMENTS build settings respectively.
info_ref = watch_group.new_reference("#{SOURCE_DIR}/Info.plist")
info_ref.last_known_file_type = 'text.plist.xml'
info_ref.set_source_tree('SOURCE_ROOT')
info_ref.set_path('Watch/Info.plist')

ent_ref = watch_group.new_reference("#{SOURCE_DIR}/ReolensWatch.entitlements")
ent_ref.last_known_file_type = 'text.plist.entitlements'
ent_ref.set_source_tree('SOURCE_ROOT')
ent_ref.set_path('Watch/ReolensWatch.entitlements')

# --- 4. Link AppWatch SPM product ----------------------------------------
# Find the existing Swift package reference for the Reolens local package
# (added by the iOS target).
pkg_ref = project.root_object.package_references.find do |ref|
  rel = ref.respond_to?(:relative_path) ? ref.relative_path : nil
  rel ||= ref.respond_to?(:path) ? ref.path : nil
  rel == '..'
end
unless pkg_ref
  warn 'Could not find local Swift package reference (../). Aborting.'
  exit 2
end

# Add the AppWatch product as a dependency on the watch target.
pkg_product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
pkg_product_dep.package = pkg_ref
pkg_product_dep.product_name = 'AppWatch'
watch_target.package_product_dependencies << pkg_product_dep

# And add a Frameworks build file that references the product so the
# linker pulls it in.
frameworks_phase = watch_target.frameworks_build_phase
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = pkg_product_dep
frameworks_phase.files << build_file

# --- 5. Embed the watch app inside the iOS app ---------------------------
ios_target = project.targets.find { |t| t.name == 'ReolensiOS' }
unless ios_target
  warn 'Could not find ReolensiOS target. Aborting.'
  exit 3
end

# Target dependency: iOS target depends on watch target so it builds first.
dep = project.new(Xcodeproj::Project::Object::PBXTargetDependency)
proxy = project.new(Xcodeproj::Project::Object::PBXContainerItemProxy)
proxy.container_portal = project.root_object.uuid
proxy.proxy_type = '1'
proxy.remote_global_id_string = watch_target.uuid
proxy.remote_info = TARGET_NAME
dep.target = watch_target
dep.target_proxy = proxy
ios_target.dependencies << dep

# "Embed Watch Content" copy-files phase on the iOS target. Destination
# code 16 (Plug-ins) is what Xcode's WKApplication template uses; the
# subfolder string `$(CONTENTS_FOLDER_PATH)/Watch` puts the .app into
# the embedded-watch slot the system loader expects.
embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_phase.name = 'Embed Watch Content'
embed_phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
embed_phase.dst_subfolder_spec = '16'
embed_phase.run_only_for_deployment_postprocessing = '0'
ios_target.build_phases << embed_phase

embed_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
embed_build_file.file_ref = watch_target.product_reference
embed_build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
embed_phase.files << embed_build_file

# --- 6. Save and report ---------------------------------------------------
project.save

puts "Added target '#{TARGET_NAME}' to #{PROJECT_PATH}"
puts "Bundle ID: #{BUNDLE_ID}"
puts "Embedded inside: #{ios_target.name}"
puts "SPM product: AppWatch"
puts
puts 'Next: xcodebuild -project ReolensiOS.xcodeproj -list'
