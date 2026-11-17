cask "alttab2" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.0"
  sha256 arm:   "b8e690be4cb41b7bc98111a783a3702f52307b00498865ff53eec4e2cf124cd3",
         intel: "2505871cc75e0c885baf497cf487ab8feb16cd81eb44eef12f7ba217bc6f7d43"

  url "https://github.com/glasss13/alttab2/releases/download/v#{version}/AltTab2-#{arch}.zip"
  name "AltTab2"
  desc "Keyboard-driven window switcher"
  homepage "https://github.com/glasss13/alttab2"

  depends_on macos: ">= :tahoe"

  app "AltTab2.app"
end
