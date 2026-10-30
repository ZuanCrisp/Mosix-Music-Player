Pod::Spec.new do |spec|
  spec.name = 'MosixBackend'
  spec.version = '0.1.0'
  spec.summary = 'Rust backend bindings for Mosix'
  spec.homepage = 'https://github.com/ZuanCrisp/Mosix-Music-Player'
  spec.license = { :type => 'MIT', :file => 'LICENSE' }
  spec.author = { 'ZuanCrisp' => 'noreply@mosix.local' }
  spec.source = { :path => '.' }
  spec.ios.deployment_target = '16.0'
  spec.swift_version = '5.0'
  spec.static_framework = true
  # build_rust_backend.sh stages this spec beside the generated iOS artifacts.
  spec.source_files = 'MosixBackend.swift'
  spec.vendored_frameworks = 'MosixBackendFFI.xcframework'
  spec.frameworks = 'Security', 'CoreFoundation'
end
