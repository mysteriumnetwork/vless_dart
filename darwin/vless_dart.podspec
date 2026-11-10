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

  s.source = { :path => "." }
  s.source_files = "vless_dart/Sources/vless_dart/**/*.swift", "vless_dart/Sources/vless_tunnel_support/**/*.swift"

  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES", "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "i386" }
  s.swift_version = "5.9"

  # Go's net package resolves via libresolv.
  s.libraries = "resolv"

  s.ios.dependency "Flutter"
  s.osx.dependency "FlutterMacOS"
  s.ios.deployment_target = "15.0"
  s.osx.deployment_target = "12.0"

  s.vendored_frameworks = "vless_dart/Artifacts/XRay.xcframework"
end
