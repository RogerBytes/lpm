"""
Language loader for the GUI, Python mirror of lib/zgl-lang-loader.sh.

Same file format ("key=value", one lang/<code>.lang per language), same lang/ directory
(sibling of gui/, see install.sh and packaging/{debian,rpm,arch}/*), same detection logic
(LC_ALL > LC_MESSAGES > LANG, lowercase 2-letter code) and same per-key fallback to English
when a key is missing. This keeps a single source of truth for translations (lang/en.lang,
lang/fr.lang), shared by the bash CLI and the GUI.

Deliberate differences from the bash loader:
  - No "exit 1" if lang/en.lang is missing: the GUI stays usable (raw keys are the fallback
    text) rather than crashing at startup (see _init_gui_logger in guilog.py).
  - Positional "%s"/"%d" substitution is done character by character (never with Python's %
    operator): a literal "%" in a community translation must not crash the call, same as
    documented for the "t" function of the bash loader.
"""

from __future__ import annotations

import os

STRINGS: dict[str, str] = {}


def _lang_dir() -> str:
    # gui/ and lang/ are always siblings (source checkout AND every install method, see
    # install.sh, packaging/debian/lpm.install, packaging/rpm/lpm.spec, packaging/arch/PKGBUILD).
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lang")


def _load_lang_file(path: str) -> bool:
    if not os.path.isfile(path):
        return False
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw_line in f:
                line = raw_line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                key, sep, value = line.partition("=")
                if not sep or not key:
                    continue
                STRINGS[key] = value
    except OSError:
        return False
    return True


def _detect_locale_code() -> str:
    raw = os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANG") or "en"
    code = raw.split(".")[0].split("_")[0].strip().lower()
    return code or "en"


def _init():
    lang_dir = _lang_dir()
    _load_lang_file(os.path.join(lang_dir, "en.lang"))
    code = _detect_locale_code()
    if code != "en":
        _load_lang_file(os.path.join(lang_dir, f"{code}.lang"))


_init()


def t(key: str, *args) -> str:
    """Equivalent of the bash loader's "t" function: translated text for "key" (or the key
    itself as a last resort if absent from STRINGS/en.lang), with positional substitution of
    "%s"/"%d" by the given arguments, converted with str()."""
    template = STRINGS.get(key, key)
    if not args:
        return template

    result: list[str] = []
    arg_iter = iter(args)
    i = 0
    n = len(template)
    while i < n:
        if template[i] == "%" and i + 1 < n and template[i + 1] in ("s", "d"):
            try:
                result.append(str(next(arg_iter)))
            except StopIteration:
                result.append(template[i : i + 2])
            i += 2
        else:
            result.append(template[i])
            i += 1
    return "".join(result)
