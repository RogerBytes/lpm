"""CommandPages: assembly of the page groups (one page_* method per screen)."""

from pages_home import HomePages
from pages_lifecycle import LifecyclePages
from pages_media import MediaPages
from pages_runners import RunnerPages
from pages_system import SystemPages
from pages_vsync import VsyncPages


class CommandPages(HomePages, LifecyclePages, MediaPages, RunnerPages, SystemPages, VsyncPages):
    """Builds each command screen (one page_<command>() method per screen, spread across
    the pages_*.py modules by theme). MainWindow.BUILDER_NAMES maps each sidebar entry id
    to the matching method."""

    def __init__(self, window):
        self.window = window
