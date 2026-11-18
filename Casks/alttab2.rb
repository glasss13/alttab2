cask "alttab2" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.1"
  sha256 arm:   "3dc82f15826b1c012c8d5bd2f163b76a70fbb23c05c74a64d1d0aca7c9fcddfb",
         intel: "fd90ca5ade6d69647fdb84149d6205437d18797b0c93949613d83e7f123db7d6"

  url "https://github.com/glasss13/alttab2/releases/download/v#{version}/AltTab2-#{arch}.zip"
  name "AltTab2"
  desc "Keyboard-driven window switcher"
  homepage "https://github.com/glasss13/alttab2"

  depends_on macos: :tahoe

  app "AltTab2.app"
end
