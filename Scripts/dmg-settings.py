# Settings for dmgbuild, which lays out the disk image without opening any Finder windows.
# make-release.sh passes the paths as defines. dmg-background.swift draws around the icon positions below.

app = defines["app"]
guide = defines["guide"]
guide_name = "처음 여는 방법 - How to Open.txt"

format = "ULFO"
filesystem = "APFS"

files = [app, (guide, guide_name)]
symlinks = {"Applications": "/Applications"}
# Not the app: Finder hides its extension anyway, and this setting's attribute fails strict signature checks on it.
hide_extensions = [guide_name]

icon = f"{app}/Contents/Resources/AppIcon.icns"
background = defines["background"]

default_view = "icon-view"
# The height includes Finder's title bar, which takes about 32 points.
window_rect = ((200, 120), (680, 520))
icon_size = 100
text_size = 13
icon_locations = {
    "Sampl Moa.app": (190, 195),
    "Applications": (490, 195),
    guide_name: (105, 368),
}
