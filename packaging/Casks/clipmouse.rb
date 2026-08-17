cask "clipmouse" do
  version "0.1.0"
  sha256 "d7510421aa236b74139fdc16b3c9d068375df19079c2baac51552ca3edd3c2ab"

  url "https://github.com/zeklop/clipmouse/releases/download/v#{version}/ClipMouse-#{version}.dmg"
  name "ClipMouse"
  desc "Native macOS clipboard manager — history, search, snippets, secret protection and keep-awake in one menu bar icon"
  homepage "https://github.com/zeklop/clipmouse"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "ClipMouse.app"

  zap trash: [
    "~/Library/Application Support/ClipMouse",
    "~/Library/Preferences/dev.zeklop.clipmouse.plist",
  ]
end
