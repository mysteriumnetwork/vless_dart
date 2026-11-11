Pod::Spec.new do |s|
  s.name = "vless_dart"
  s.version = "0.0.1"
  s.summary = "VLESS (darwin)"
  s.description = <<-DESC
VLESS/Xray client for iOS and macOS.
                       DESC
  s.homepage = "https://github.com/mysteriumnetwork/vless_dart"
  s.license = { :file => "../LICENSE" }
  s.author = { "Mysterium Network" => "mysterium-dev@mysterium.network" }

  # Control plane only, matching Package.swift. The data plane — Xray core,
  # tun2socks and the packet tunnel provider — lives in vless-apple and is
  # linked by the extension target, never by the app: a second Go runtime
  # beside WireGuard's does not link.
  s.source = { :path => "." }
  s.source_files = "vless_dart/Sources/vless_dart/**/*.swift"

  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES", "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "i386" }
  s.swift_version = "5.9"

  s.ios.dependency "Flutter"
  s.osx.dependency "FlutterMacOS"
  s.ios.deployment_target = "15.0"
  s.osx.deployment_target = "13.0"
end
