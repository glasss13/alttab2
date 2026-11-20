cask "alttab2" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.3"
  sha256 arm:   "b6ac77c4fcdad4e4646bd8455213318a6c74776925a628362ca45cbf039d00e1",
         intel: "795146c37ed87e628aefe68289808e5949a74fdd3f0e1bb4f946f6ebe4218547"

  url "https://github.com/glasss13/alttab2/releases/download/v#{version}/AltTab2-#{arch}.zip"
  name "AltTab2"
  desc "Keyboard-driven window switcher"
  homepage "https://github.com/glasss13/alttab2"

  depends_on macos: :tahoe

  app "AltTab2.app"
end
