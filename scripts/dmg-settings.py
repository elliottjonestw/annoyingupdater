from pathlib import Path

application = Path(defines["app"]).resolve()
files = [str(application)]
symlinks = {"Applications": "/Applications"}
format = "ULFO"
filesystem = "HFS+"
background = defines["background"]
icon = str(application / "Contents/Resources/AppIcon.icns")
window_rect = ((200, 160), (660, 420))
icon_locations = {application.name: (180, 205), "Applications": (480, 205)}
icon_size = 96
text_size = 14
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
default_view = "icon-view"
