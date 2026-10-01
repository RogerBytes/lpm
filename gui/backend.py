"""
--- Pont vers les scripts CLI de lpm (lib/*.sh), sans jamais passer par Zenity ---

Chaque fonction ici construit un argv pour "bin/lpm <commande> ... <flags CLI>", exactement
comme si on tapait la commande soi-même dans un terminal -- cette interface graphique n'est
qu'une couche AU-DESSUS des scripts CLI déjà refactorés, jamais un doublon de leur logique.

Point important : tout subprocess est lancé avec stdin=DEVNULL. Certains scripts de lib/
ont encore un "read -r -p" de repli pour un cas interactif très spécifique qui n'a pas
(encore) d'équivalent en argument CLI dédié (ex: désambiguïsation d'un nom de jeu ambigu
sur SteamGridDB) -- avec stdin fermé, ce "read" reçoit immédiatement un EOF et répond ""
(chaîne vide), que ces scripts traitent déjà comme une annulation propre de CETTE étape
précise (jamais un blocage, jamais un crash). C'est un comportement de repli acceptable
pour cette interface : aucun écran ne doit jamais rester bloqué à attendre une réponse
qui ne viendra jamais.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
from dataclasses import dataclass
from typing import Callable


def _resolve_bin_lpm() -> str:
    """Résout le chemin de "bin/lpm" : en checkout source, gui/ et bin/ sont frères (même
    dossier parent) -- mais après une installation via install.sh, "bin/lpm" part dans
    /usr/local/bin/lpm alors que ce dossier gui/ part dans /usr/local/lib/lpm/gui, donc
    PLUS frères du tout. On essaie donc d'abord le frère local (checkout source), puis on
    retombe sur le PATH (cas d'une installation standard, /usr/local/bin y est normalement)."""
    sibling = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "lpm")
    if os.path.isfile(sibling):
        return sibling
    return shutil.which("lpm") or "lpm"


BIN_LPM = _resolve_bin_lpm()


@dataclass
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


def run_lpm(args: list[str], on_line: Callable[[str], None] | None = None) -> CommandResult:
    """Lance "bin/lpm <args>" de façon synchrone (bloquante) -- à appeler uniquement
    depuis un thread d'arrière-plan, jamais depuis le thread principal GTK (sans quoi
    toute l'interface se gèle pendant la durée de la commande)."""
    proc = subprocess.Popen(
        [BIN_LPM, *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    out_lines: list[str] = []

    if on_line is not None and proc.stdout is not None:
        for line in proc.stdout:
            out_lines.append(line)
            on_line(line.rstrip("\n"))
        stdout = "".join(out_lines)
        _, stderr = proc.communicate()
    else:
        stdout, stderr = proc.communicate()

    return CommandResult(returncode=proc.returncode, stdout=stdout, stderr=stderr)


def run_lpm_async(
    args: list[str],
    on_line: Callable[[str], None] | None = None,
    on_done: Callable[[CommandResult], None] | None = None,
) -> threading.Thread:
    """Variante non bloquante : lance run_lpm() dans un thread séparé. on_line/on_done
    sont appelés depuis CE thread d'arrière-plan -- à l'appelant de les re-poster sur le
    thread principal GTK via GLib.idle_add avant de toucher un quelconque widget."""

    def _worker():
        result = run_lpm(args, on_line=on_line)
        if on_done is not None:
            on_done(result)

    thread = threading.Thread(target=_worker, daemon=True)
    thread.start()
    return thread


# --- Listers : parsing du texte déjà produit par lib/zg*-lister.sh ---

_SLUG_NAME_RE = re.compile(r"^(\S+)\s+(.*)$")


@dataclass
class GameEntry:
    slug: str
    name: str


@dataclass
class IsolableEntry:
    slug: str
    name: str
    store_label: str


def list_games() -> list[GameEntry]:
    result = run_lpm(["list"])
    entries: list[GameEntry] = []
    for line in result.stdout.splitlines():
        m = _SLUG_NAME_RE.match(line.strip())
        if m:
            entries.append(GameEntry(slug=m.group(1), name=m.group(2)))
    return entries


def list_runners() -> list[str]:
    result = run_lpm(["list-runner"])
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def list_remote_runners() -> list[str]:
    result = run_lpm(["list-remote-runners"])
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def list_isolable() -> list[IsolableEntry]:
    result = run_lpm(["list-isolable"])
    entries: list[IsolableEntry] = []
    for line in result.stdout.splitlines():
        parts = re.split(r"\s{2,}", line.strip())
        if len(parts) >= 3:
            entries.append(IsolableEntry(slug=parts[0], name=parts[1], store_label=parts[2]))
    return entries
