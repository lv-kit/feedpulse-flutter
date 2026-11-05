Pod::Spec.new do |s|
  s.name             = 'feedpulse'
  s.version          = '0.1.0'
  s.summary          = 'Feedpulse Flutter SDK native side (App Attest).'
  s.description      = 'App attestation (DeviceCheck App Attest), device info and config storage for the Feedpulse Flutter SDK.'
  s.homepage         = 'https://github.com/lv-kit/feedpulse-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'lv-kit' => 'https://github.com/lv-kit' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '14.0'
  s.frameworks       = 'DeviceCheck', 'CryptoKit'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
