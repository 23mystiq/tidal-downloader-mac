"""Headless backend for the native macOS front end (macos/TidalDL).

Speaks newline-delimited JSON over stdin/stdout:

- request:  {"id": 1, "method": "search", "params": {...}}
- response: {"id": 1, "result": ...} or {"id": 1, "error": "..."}
- event:    {"event": "log", "data": {...}}

It drives the same building blocks as the Qt GUI (`gui.py`): `Tidal`, `Settings`, `Download`, the
helpers in `helper/tidal.py` and the queue semantics of `MainWindow`. TIDAL objects never leave this
process; the front end refers to them by opaque handles.
"""

import copy
import json
import logging
import os
import shutil
import sys
import threading
import time
import traceback
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from typing import Any

# The protocol owns the real stdout. Everything else that writes to fd 1 (C extensions, stray prints)
# is redirected to stderr, and Python-level prints become log lines like in the Qt GUI.
_PROTO = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
os.dup2(2, 1)
_WRITE_LOCK = threading.Lock()


def _send(obj: dict) -> None:
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":"), default=str)

    with _WRITE_LOCK:
        _PROTO.write(line + "\n")
        _PROTO.flush()


def emit(event: str, data: Any = None) -> None:
    _send({"event": event, "data": data})


class _EventLogHandler(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        try:
            emit("log", {"level": record.levelname.lower(), "message": self.format(record)})
        except Exception:
            pass


class _PrintToLog:
    """Replacement for sys.stdout: complete lines become info log events (the Qt GUI did the same)."""

    def __init__(self):
        self._buf = ""

    def write(self, text: str) -> int:
        self._buf += text

        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)

            if line.strip():
                emit("log", {"level": "info", "message": line})

        return len(text)

    def flush(self) -> None:
        pass


sys.stdout = _PrintToLog()

logger = logging.getLogger("tidal_dl_ng.bridge")
_handler = _EventLogHandler()
_handler.setFormatter(logging.Formatter("%(message)s"))
logger.addHandler(_handler)
logger.setLevel(logging.DEBUG)
logger.propagate = False

from requests.adapters import HTTPAdapter  # noqa: E402
from requests.exceptions import HTTPError  # noqa: E402
from rich.progress import Progress  # noqa: E402
from tidalapi import Album, Mix, Playlist, Quality, Track, UserPlaylist, Video  # noqa: E402
from tidalapi.artist import Artist  # noqa: E402
from tidalapi.session import LinkLogin  # noqa: E402

from tidal_dl_ng import __version__, update_available  # noqa: E402
from tidal_dl_ng.config import HandlingApp, Settings, Tidal  # noqa: E402
from tidal_dl_ng.constants import FAVORITES, CoverDimensions, QualityVideo, QueueDownloadStatus  # noqa: E402
from tidal_dl_ng.download import Download  # noqa: E402
from tidal_dl_ng.helper.path import get_format_template  # noqa: E402
from tidal_dl_ng.helper.tidal import (  # noqa: E402
    favorite_function_factory,
    get_tidal_media_id,
    get_tidal_media_type,
    instantiate_media,
    items_results_all,
    name_builder_artist,
    name_builder_title,
    quality_audio_highest,
)
from tidal_dl_ng.model.cfg import HelpSettings  # noqa: E402

SEARCH_TYPES: dict[str, type] = {"Artist": Artist, "Album": Album, "Track": Track, "Video": Video, "Playlist": Playlist}

# Same field groups the Qt preferences dialog exposes (dialog.py: DialogPreferences).
PREF_CHECKBOXES: list[str] = [
    "lyrics_embed",
    "lyrics_file",
    "video_download",
    "download_delay",
    "video_convert_mp4",
    "extract_flac",
    "metadata_cover_embed",
    "cover_album_file",
    "skip_existing",
    "symlink_to_track",
    "playlist_create",
]
PREF_LINE_EDITS: list[str] = [
    "download_base_path",
    "format_album",
    "format_playlist",
    "format_mix",
    "format_track",
    "format_video",
    "path_binary_ffmpeg",
]
PREF_SPIN_BOXES: list[str] = ["album_track_num_pad_min", "downloads_concurrent_max"]
PREF_COMBOS: dict[str, type] = {
    "quality_audio": Quality,
    "quality_video": QualityVideo,
    "metadata_cover_dimension": CoverDimensions,
}

# Status order matters for the front end only; the values are the Qt GUI's status markers.
STATUS_NAMES: dict[str, str] = {
    QueueDownloadStatus.Waiting: "waiting",
    QueueDownloadStatus.Downloading: "downloading",
    QueueDownloadStatus.Finished: "finished",
    QueueDownloadStatus.Failed: "failed",
    QueueDownloadStatus.Skipped: "skipped",
}


class _Signal:
    """Stands in for a Qt signal in `ProgressBars`; coalesces bursts so the UI is not flooded."""

    def __init__(self, bar: str, field: str, min_interval: float = 1 / 30):
        self.bar = bar
        self.field = field
        self.min_interval = min_interval
        self._last = 0.0

    def emit(self, value: Any) -> None:
        now = time.monotonic()

        if self.field == "value":
            final = value is None or value <= 0 or value >= 100

            if not final and now - self._last < self.min_interval:
                return

        self._last = now
        emit("progress", {"bar": self.bar, self.field: value})


class QueueItem:
    def __init__(self, qid: int, name: str, type_media: str, quality_audio, quality_video, obj):
        self.qid = qid
        self.status: str = QueueDownloadStatus.Waiting
        self.name = name
        self.type_media = type_media
        self.quality_audio = quality_audio
        self.quality_video = quality_video
        self.obj = obj

    def to_dict(self, bridge: "Bridge") -> dict:
        return {
            "qid": self.qid,
            "status": STATUS_NAMES[self.status],
            "name": self.name,
            "type": self.type_media,
            "qualityAudio": str(self.quality_audio.value if hasattr(self.quality_audio, "value") else self.quality_audio),
            "qualityVideo": str(
                self.quality_video.value if hasattr(self.quality_video, "value") else self.quality_video
            ),
            "cover": bridge.cover_url(self.obj),
        }


class Bridge:
    def __init__(self):
        self.settings: Settings = Settings()
        self.tidal: Tidal | None = None
        self.dl: Download | None = None
        self.link_login: LinkLogin | None = None
        self.pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="bridge")
        self.pool_io = ThreadPoolExecutor(max_workers=12, thread_name_prefix="io")
        self.handles: dict[str, Any] = {}
        self.handle_next: int = 0
        self.handle_lock = threading.Lock()
        self.queue: list[QueueItem] = []
        self.queue_lock = threading.Lock()
        self.queue_wakeup = threading.Event()
        self.queue_next: int = 0
        self.search_current: int = -1
        self.handling_app: HandlingApp = HandlingApp()
        self.handling_app.event_run.set()

        threading.Thread(target=self.watcher_queue_download, name="queue", daemon=True).start()

    # ---------------------------------------------------------------- handles

    def handle(self, obj: Any) -> str:
        with self.handle_lock:
            self.handle_next += 1
            key = str(self.handle_next)
            self.handles[key] = obj

        return key

    def resolve(self, key: str) -> Any:
        if key in FAVORITES:
            return key

        return self.handles[key]

    # ---------------------------------------------------------------- media helpers

    @staticmethod
    def cover_url(media: Any, dimensions: int | None = None) -> str:
        """Same lookup order as MainWindow.cover_show: album cover first, then the item's own image."""
        candidates: list[Callable] = []

        try:
            candidates.append(media.album.image)
        except Exception:
            pass

        if hasattr(media, "image"):
            candidates.append(media.image)

        for fn in candidates:
            try:
                return fn(dimensions) if dimensions else fn()
            except Exception:
                continue

        if dimensions:
            return Bridge.cover_url(media)

        return ""

    @staticmethod
    def share_url(media: Any) -> str:
        return media.share_url if hasattr(media, "share_url") else "No share URL available."

    def result_items(self, items: list, position_base: int = 0) -> list[dict]:
        """Port of MainWindow.search_result_to_model, producing plain dicts."""
        result: list[dict] = []

        for idx, item in enumerate(items or []):
            if hasattr(item, "available") and not item.available:
                continue

            explicit: bool = bool(item.explicit) if isinstance(item, Track | Video | Album) else False
            user_date_added = getattr(item, "user_date_added", None)
            date_user_added: str = user_date_added.strftime("%Y-%m-%d %H:%M") if user_date_added else ""
            row: dict | None = None

            if isinstance(item, Track):
                row = {
                    "artist": name_builder_artist(item),
                    "title": name_builder_title(item),
                    "album": item.album.name,
                    "duration": item.duration,
                    "quality": str(quality_audio_highest(item)),
                }
            elif isinstance(item, Video):
                row = {
                    "artist": name_builder_artist(item),
                    "title": name_builder_title(item),
                    "album": item.album.name if item.album else "",
                    "duration": item.duration,
                    "quality": str(item.video_quality),
                }
            elif isinstance(item, Playlist):
                row = {
                    "artist": ", ".join(a.name for a in item.promoted_artists) if item.promoted_artists else "",
                    "title": item.name,
                    "album": "",
                    "duration": item.duration,
                    "quality": "",
                }
            elif isinstance(item, Album):
                row = {
                    "artist": name_builder_artist(item),
                    "title": "",
                    "album": item.name,
                    "duration": item.duration,
                    "quality": str(quality_audio_highest(item)),
                }
            elif isinstance(item, Mix):
                row = {"artist": item.sub_title, "title": item.title, "album": "", "duration": -1, "quality": ""}
            elif isinstance(item, Artist):
                row = {"artist": item.name, "title": "", "album": "", "duration": -1, "quality": ""}

            if row is None:
                continue

            row.update(
                {
                    "h": self.handle(item),
                    "position": position_base + idx,
                    "kind": type(item).__name__,
                    "explicit": explicit,
                    "added": date_user_added,
                    "expandable": isinstance(item, Mix | Playlist | Album | Artist),
                    "thumb": self.cover_url(item, 160),
                    "cover": self.cover_url(item),
                    "share": self.share_url(item),
                }
            )
            result.append(row)

        return result

    def media_to_queue_item(self, media: Any) -> QueueItem | None:
        """Port of MainWindow.media_to_queue_download_model."""
        name: str = ""
        quality_audio: Quality = self.settings.data.quality_audio
        quality_video: QualityVideo = self.settings.data.quality_video
        explicit: str = ""

        if hasattr(media, "available") and not media.available:
            return None

        if isinstance(media, Track | Video | Album):
            explicit = " 🅴" if media.explicit else ""

        if isinstance(media, Track | Video):
            name = f"{name_builder_artist(media)} - {name_builder_title(media)}{explicit}"
        elif isinstance(media, Playlist | Artist):
            name = media.name
        elif isinstance(media, Album):
            name = f"{name_builder_artist(media)} - {media.name}{explicit}"
        elif isinstance(media, Mix):
            name = media.title

        if isinstance(media, Track | Album):
            quality_highest: Quality = quality_audio_highest(media)

            if (
                self.settings.data.quality_audio == quality_highest
                or self.settings.data.quality_audio == Quality.hi_res_lossless
            ):
                quality_audio = quality_highest

        if not name:
            return None

        with self.queue_lock:
            self.queue_next += 1
            qid = self.queue_next

        return QueueItem(qid, name, type(media).__name__, quality_audio, quality_video, media)

    # ---------------------------------------------------------------- session

    def ffmpeg_resolve(self) -> None:
        """Point `path_binary_ffmpeg` at a working FFmpeg if the configured one is missing.

        Apps started from Finder get a minimal PATH, so the usual install locations are checked as well.
        """
        configured: str = os.path.expanduser(self.settings.data.path_binary_ffmpeg or "")

        if configured and os.access(configured, os.X_OK):
            return

        candidates = [shutil.which("ffmpeg"), "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        found = next((c for c in candidates if c and os.access(c, os.X_OK)), None)

        if found:
            if configured:
                logger.warning(f"FFmpeg not found at '{configured}'. Using '{found}' instead.")
            else:
                logger.info(f"Using FFmpeg at '{found}'.")

            self.settings.data.path_binary_ffmpeg = found
            self.settings.save()
        elif configured:
            logger.error(f"FFmpeg not found at '{configured}'. Install it (brew install ffmpeg) or set its path in Settings.")

    def init_dl(self) -> None:
        """Port of MainWindow._init_dl."""
        self.ffmpeg_resolve()
        data_pb = SimpleNamespace(
            item=_Signal("item", "value"),
            list_item=_Signal("list", "value"),
            item_name=_Signal("item", "name"),
            list_name=_Signal("list", "name"),
        )
        self.dl = Download(
            session=self.tidal.session,
            skip_existing=self.tidal.settings.data.skip_existing,
            path_base=self.settings.data.download_base_path,
            fn_logger=logger,
            progress_gui=data_pb,
            progress=Progress(),
            event_abort=self.handling_app.event_abort,
            event_run=self.handling_app.event_run,
        )

    def after_login(self) -> None:
        self.init_dl()
        self.pool.submit(self._safe, self.load_user_lists)

    def m_init(self, params: dict) -> dict:
        self.tidal = Tidal(self.settings)
        # Room for the concurrent metadata requests (requests' default pool keeps only 10 connections).
        self.tidal.session.request_session.mount("https://", HTTPAdapter(pool_connections=4, pool_maxsize=32))
        logged_in: bool = self.tidal.login_token()

        if logged_in:
            self.after_login()

        logger.debug("All setup.")

        return {
            "loggedIn": logged_in,
            "isPkce": bool(self.tidal.session.is_pkce) if logged_in else False,
            "version": __version__,
            "settings": self.settings_dict(),
        }

    def m_login_link(self, params: dict) -> dict:
        self.link_login = self.tidal.session.get_link_login()

        return {
            "url": f"https://{self.link_login.verification_uri_complete}",
            "expiresIn": self.link_login.expires_in,
        }

    def m_login_complete(self, params: dict) -> dict:
        try:
            self.tidal.session.process_link_login(self.link_login, until_expiry=False)
            self.tidal.login_finalize()
        except (HTTPError, Exception):
            logger.warning("Login not successful. Try again...")

            return {"ok": False, "hint": "Something was wrong with your redirect url. Please try again!"}

        logger.info("Login successful. Have fun!")
        self.after_login()

        return {"ok": True}

    def m_login_pkce_url(self, params: dict) -> dict:
        """PKCE login: the only login TIDAL still serves lossless FLAC to (tidalapi issue #404)."""
        return {
            "url": self.tidal.session.pkce_login_url(),
            "redirect": self.tidal.session.config.pkce_uri_redirect,
        }

    def m_login_pkce_complete(self, params: dict) -> dict:
        was_logged_in: bool = self.dl is not None

        try:
            token = self.tidal.session.pkce_get_auth_token(params["url"])
            self.tidal.session.process_auth_token(token, is_pkce_token=True)

            if not self.tidal.login_finalize():
                raise Exception("Login could not be verified.")
        except Exception as e:
            logger.warning(f"Login not successful. Try again... ({e})")

            return {"ok": False, "hint": "TIDAL did not accept this login. Please try again."}

        logger.info("Login successful (lossless enabled). Have fun!")

        if was_logged_in:
            self.init_dl()
        else:
            self.after_login()

        return {"ok": True, "isPkce": True}

    def m_search_cancel(self, params: dict) -> dict:
        self.search_current = -1

        return {}

    def m_logout(self, params: dict) -> dict:
        return {"ok": bool(self.tidal.logout())}

    # ---------------------------------------------------------------- lists

    def user_playlists(self) -> list:
        """Same result as paginate_results([session.user.playlist_and_favorite_playlists]).

        tidalapi turns every playlist the user owns into a `UserPlaylist`, which costs one request each, made one
        after another (~0.3 s x n). Here the pages are parsed the same way but those requests run concurrently.
        """
        session = self.tidal.session
        user = session.user
        result: list = []
        limit: int = 50
        offset: int = 0

        while True:
            json_obj = user.request.request(
                "GET", f"users/{user.id}/playlistsAndFavoritePlaylists", params={"limit": limit, "offset": offset}
            ).json()
            parsed: list[Playlist] = []

            for item in json_obj["items"]:
                item["playlist"]["dateAdded"] = item["created"]
                playlist = Playlist(session, None)
                playlist.parse(item["playlist"])
                parsed.append(playlist)

            if not parsed:
                break

            result += list(self.pool_io.map(lambda p: copy.copy(p.factory()), parsed))
            offset += limit

        return result

    def load_user_lists(self) -> None:
        emit("userListsLoading", True)

        try:
            user_all = self.user_playlists() + self.tidal.session.mixes().categories[0].items
            playlists: list[dict] = []
            mixes: list[dict] = []

            for item in user_all:
                if isinstance(item, UserPlaylist | Playlist):
                    description: str = f" {item.description}" if item.description else ""
                    playlists.append(
                        {
                            "h": self.handle(item),
                            "name": item.name,
                            "info": f"({item.num_tracks + item.num_videos} Tracks){description}",
                            "count": item.num_tracks + item.num_videos,
                            "thumb": self.cover_url(item, 160),
                            "cover": self.cover_url(item),
                            "share": self.share_url(item),
                        }
                    )
                elif isinstance(item, Mix):
                    mixes.append(
                        {
                            "h": self.handle(item),
                            "name": item.title,
                            "info": item.sub_title,
                            "thumb": self.cover_url(item),
                            "cover": self.cover_url(item),
                            "share": self.share_url(item),
                        }
                    )

            favorites = [{"h": key, "name": fav["name"]} for key, fav in FAVORITES.items()]
            emit("userLists", {"playlists": playlists, "mixes": mixes, "favorites": favorites})
        finally:
            emit("userListsLoading", False)

    def m_user_lists_reload(self, params: dict) -> dict:
        self.load_user_lists()

        return {}

    def m_list_items(self, params: dict) -> dict:
        """Port of MainWindow.list_items_show_result (also used for lazy expansion of result rows)."""
        media_list = self.resolve(params["h"])

        if isinstance(media_list, str):
            media_items = favorite_function_factory(self.tidal, media_list)()
        else:
            media_items = items_results_all(media_list)

        return {"items": self.result_items(media_items)}

    def m_search(self, params: dict) -> dict:
        """Port of MainWindow.search, streaming each page as it arrives (`searchPage` events)."""
        sid: int = params["sid"]
        query: str = params["query"].strip()
        self.search_current = sid

        if "http" in query:
            media_type = get_tidal_media_type(query)
            item_id = get_tidal_media_id(query)

            try:
                media = instantiate_media(self.tidal.session, media_type, item_id)
            except Exception:
                logger.error(f"Media not found (ID: {item_id}). Maybe it is not available anymore.")
                media = None

            emit("searchPage", {"sid": sid, "items": self.result_items([media] if media else [])})

            return {"sid": sid}

        # Same pagination as helper.tidal.search_results_all, but each page is shown immediately.
        types_media = [SEARCH_TYPES[params["type"]]]
        limit: int = 300
        offset: int = 0
        counts: dict[str, int] = {}

        while self.search_current == sid:
            page = self.tidal.session.search(query=query, models=types_media, limit=limit, offset=offset)
            got_any: bool = False

            for key, value in page.items():
                # top_hit is a single object repeated on every page; the Qt GUI never listed it either.
                if key == "top_hit" or not isinstance(value, list) or not value:
                    continue

                got_any = True
                base = counts.get(key, 0)
                counts[key] = base + len(value)

                if self.search_current == sid:
                    emit("searchPage", {"sid": sid, "items": self.result_items(value, position_base=base)})

            if not got_any:
                break

            offset += limit

        return {"sid": sid}

    # ---------------------------------------------------------------- queue

    def queue_add(self, media: Any) -> None:
        item = self.media_to_queue_item(media)

        if item:
            with self.queue_lock:
                self.queue.append(item)

            emit("queueAdded", item.to_dict(self))
            self.queue_wakeup.set()

    def m_queue_add(self, params: dict) -> dict:
        for key in params["handles"]:
            self.queue_add(self.resolve(key))

        return {}

    def _queue_drop(self, predicate: Callable[[QueueItem], bool]) -> list[int]:
        with self.queue_lock:
            dropped = [i.qid for i in self.queue if predicate(i)]
            self.queue = [i for i in self.queue if i.qid not in dropped]

        return dropped

    def m_queue_remove(self, params: dict) -> dict:
        qids: set[int] = set(params["qids"])

        if any(i.qid in qids and i.status == QueueDownloadStatus.Downloading for i in self.queue):
            logger.info("Cannot remove a currently downloading item from queue.")

        return {
            "removed": self._queue_drop(lambda i: i.qid in qids and i.status != QueueDownloadStatus.Downloading)
        }

    def m_queue_clear_finished(self, params: dict) -> dict:
        return {"removed": self._queue_drop(lambda i: i.status == QueueDownloadStatus.Finished)}

    def m_queue_clear_all(self, params: dict) -> dict:
        statuses = (QueueDownloadStatus.Waiting, QueueDownloadStatus.Finished, QueueDownloadStatus.Failed)

        return {"removed": self._queue_drop(lambda i: i.status in statuses)}

    def m_queue_set_running(self, params: dict) -> dict:
        if params["running"]:
            self.handling_app.event_run.set()
        else:
            self.handling_app.event_run.clear()

        return {"running": self.handling_app.event_run.is_set()}

    def set_status(self, item: QueueItem, status: str) -> None:
        item.status = status
        emit("queueStatus", {"qid": item.qid, "status": STATUS_NAMES[status]})

    def watcher_queue_download(self) -> None:
        """Port of MainWindow.watcher_queue_download: one queue item at a time, oldest first."""
        while not self.handling_app.event_abort.is_set():
            with self.queue_lock:
                item = next((i for i in self.queue if i.status == QueueDownloadStatus.Waiting), None)

            if item is None or self.dl is None:
                self.queue_wakeup.wait(2)
                self.queue_wakeup.clear()

                continue

            try:
                self.set_status(item, QueueDownloadStatus.Downloading)
                result = self.on_queue_download(item.obj, item.quality_audio, item.quality_video)

                if result == QueueDownloadStatus.Finished:
                    self.set_status(item, QueueDownloadStatus.Finished)
                elif result == QueueDownloadStatus.Skipped:
                    self.set_status(item, QueueDownloadStatus.Skipped)
            except Exception as e:
                logger.error(e)
                self.set_status(item, QueueDownloadStatus.Failed)

    def on_queue_download(self, media: Any, quality_audio, quality_video) -> str:
        if isinstance(media, Artist):
            items_media = items_results_all(media)
        else:
            items_media = [media]

        download_delay: bool = bool(isinstance(media, Track | Video) and self.settings.data.download_delay)

        for item_media in items_media:
            result = self.download(item_media, delay_track=download_delay, q_audio=quality_audio, q_video=quality_video)

        return result

    def download(self, media: Any, delay_track: bool, q_audio, q_video) -> str:
        """Port of MainWindow.download."""
        emit("progressReset")
        emit("status", {"message": "Download started...", "timeout": 0})

        file_template = get_format_template(media, self.settings)

        if isinstance(media, Track | Video):
            result_dl, path_file = self.dl.item(
                media=media,
                file_template=file_template,
                download_delay=delay_track,
                quality_audio=q_audio,
                quality_video=q_video,
            )
        elif isinstance(media, Album | Playlist | Mix):
            self.dl.items(
                media=media,
                file_template=file_template,
                video_download=self.settings.data.video_download,
                download_delay=self.settings.data.download_delay,
                quality_audio=q_audio,
                quality_video=q_video,
            )
            result_dl = True
            path_file = "dummy"

        emit("status", {"message": "Download finished.", "timeout": 2000})

        if result_dl and path_file:
            return QueueDownloadStatus.Finished
        elif not result_dl and path_file:
            return QueueDownloadStatus.Skipped

        return QueueDownloadStatus.Failed

    # ---------------------------------------------------------------- settings

    def settings_dict(self) -> dict:
        help_settings = HelpSettings()

        return {
            "values": json.loads(self.settings.data.to_json()),
            "options": {
                key: [{"value": str(v.value), "name": v.name} for v in enum] for key, enum in PREF_COMBOS.items()
            },
            "help": {
                key: getattr(help_settings, key, "")
                for key in PREF_CHECKBOXES + PREF_LINE_EDITS + PREF_SPIN_BOXES + list(PREF_COMBOS)
            },
            "fields": {
                "checkboxes": PREF_CHECKBOXES,
                "lineEdits": PREF_LINE_EDITS,
                "spinBoxes": PREF_SPIN_BOXES,
                "combos": list(PREF_COMBOS),
            },
        }

    def m_settings_get(self, params: dict) -> dict:
        return self.settings_dict()

    def m_settings_update(self, params: dict) -> dict:
        """Port of DialogPreferences.to_settings + MainWindow.on_settings_save."""
        for key, value in params["values"].items():
            if key in PREF_COMBOS:
                value = PREF_COMBOS[key](value)
            elif key in PREF_SPIN_BOXES:
                value = int(value)
            elif key in PREF_CHECKBOXES:
                value = bool(value)
            elif key in PREF_LINE_EDITS:
                value = str(value)
            else:
                continue

            setattr(self.settings.data, key, value)

        self.settings.save()

        if self.tidal:
            self.tidal.settings_apply()

            if self.dl:
                self.init_dl()

        return self.settings_dict()

    # ---------------------------------------------------------------- app

    def m_update_check(self, params: dict) -> dict:
        is_available, info = update_available()
        # A failed lookup comes back as "v0.0.0", which update_available() reports as a new version.
        failed: bool = info.version == "v0.0.0"

        return {
            "available": is_available and not failed,
            "version": info.version,
            "url": info.url,
            "releaseInfo": info.release_info,
            "error": failed,
        }

    def m_shutdown(self, params: dict) -> dict:
        self.handling_app.event_abort.set()
        self.queue_wakeup.set()

        return {}

    # ---------------------------------------------------------------- dispatch

    @staticmethod
    def _safe(fn: Callable, *args) -> None:
        try:
            fn(*args)
        except Exception as e:
            logger.error(f"{e}\n{traceback.format_exc()}")

    def dispatch(self, request: dict) -> None:
        rid = request.get("id")
        method = "m_" + request.get("method", "").replace(".", "_")
        fn = getattr(self, method, None)

        if fn is None:
            _send({"id": rid, "error": f"Unknown method {request.get('method')}"})

            return

        try:
            result = fn(request.get("params") or {})
            _send({"id": rid, "result": result})
        except Exception as e:
            logger.error(f"{e}\n{traceback.format_exc()}")
            _send({"id": rid, "error": str(e) or type(e).__name__})

    def serve(self) -> None:
        for line in sys.stdin:
            line = line.strip()

            if not line:
                continue

            try:
                request = json.loads(line)
            except json.JSONDecodeError:
                continue

            self.pool.submit(self.dispatch, request)

            if request.get("method") == "shutdown":
                break

        self.handling_app.event_abort.set()
        # Wake a paused download so it can observe the abort flag.
        self.handling_app.event_run.set()


def main() -> None:
    emit("ready", {"version": __version__})
    Bridge().serve()
    os._exit(0)


if __name__ == "__main__":
    main()
