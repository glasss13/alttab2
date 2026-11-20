cask "alttab2" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.2"
  sha256 arm:   "6500ce1f1f7f46056f52312e423234b069883218f1ccb2f14a0a844625b2f438",
         intel: "634f500686c47d5fab304d5f4331984b8cc7005e7c9934beddea31c866d3cfd9"

  url "https://github.com/glasss13/alttab2/releases/download/v#{version}/AltTab2-#{arch}.zip"
  name "AltTab2"
  desc "Keyboard-driven window switcher"
  homepage "https://github.com/glasss13/alttab2"

  depends_on macos: :tahoe

  app "AltTab2.app"
end
