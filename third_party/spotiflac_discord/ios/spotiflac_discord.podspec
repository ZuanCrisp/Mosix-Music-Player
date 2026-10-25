Pod::Spec.new do |s|
  s.name = 'spotiflac_discord'
  s.version = '0.1.0'
  s.summary = 'Playback presence through the Discord Social SDK.'
  s.homepage = 'https://github.com/spotiflacapp/SpotiFLAC-Mobile'
  s.license = { :type => 'MIT' }
  s.author = 'SpotiFLAC'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '16.0'
  sdk = 'Frameworks/discord_partner_sdk.xcframework'
  if ENV['SPOTIFLAC_DISCORD_SDK'] != '0' && File.directory?(File.join(__dir__, sdk))
    s.vendored_frameworks = sdk
    s.resources = 'Frameworks/Discord-License-Notices.txt'
    s.pod_target_xcconfig = {
      'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
      'OTHER_LDFLAGS' => '$(inherited) -framework discord_partner_sdk',
      'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) SPOTIFLAC_DISCORD_SDK=1',
      'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64'
    }
    # The official SDK contains an arm64 simulator slice only.
    s.user_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64' }
  end
end
