"""Pages: shortcuts, images, tools, launchers, lsfg. Each page is built by its own module."""

from pages_images import ImagesPage
from pages_launcher import LauncherPage
from pages_lsfg import LsfgPage
from pages_shortcut import ShortcutPage
from pages_tools import ToolsPage


class MediaPages:
    def page_shortcut(self):
        return ShortcutPage(self.window).build()

    def page_images(self):
        return ImagesPage(self.window).build()

    def page_tools(self):
        return ToolsPage(self.window).build()

    def page_launcher(self):
        return LauncherPage(self.window).build()

    def page_lsfg(self):
        return LsfgPage(self.window).build()
