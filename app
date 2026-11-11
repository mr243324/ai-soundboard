import collections
import io
import json
import queue
import threading
import time
import wave
from pathlib import Path

import customtkinter as ctk
import httpx
import keyboard
import sounddevice as sd
from fishaudio import FishAudio
from fishaudio import exceptions as fish_errors
from fishaudio.types.tts import TTSConfig

CONFIG_PATH = Path(__file__).with_name("config.json")
API_URL = "https://api.fish.audio"
KEEPALIVE_SECONDS = 300
WARM_THROTTLE_SECONDS = 3
SAMPLE_RATE = 44100
BYTES_PER_SAMPLE = 2
PREBUFFER_BYTES = int(SAMPLE_RATE * BYTES_PER_SAMPLE * 0.15)
MIC_SAMPLE_RATE = 16000
MIC_BLOCK_FRAMES = 800
PREROLL_BLOCKS = 6
MIN_RECORDING_SECONDS = 0.4
NO_DEVICE = "(none)"
DEFAULT_MIC = "(system default)"
VB_CABLE_URL = "https://vb-audio.com/Cable/"

BG = "#0e1116"
CARD = "#161b22"
CARD_HOVER = "#1f2630"
BORDER = "#262d38"
TEXT = "#e6edf3"
MUTED = "#8b949e"
ACCENT = "#4f8cff"
ACCENT_HOVER = "#3a74e0"
RED = "#ff4d5e"
RED_HOVER = "#e03a4b"
AMBER = "#f5a524"
GREEN = "#3ddc84"

STATE_STYLES = {
    "ready": (GREEN, "Ready"),
    "recording": (RED, "Recording"),
    "transcribing": (AMBER, "Transcribing"),
    "generating": (AMBER, "Generating"),
    "playing": (ACCENT, "Playing"),
    "stopped": (MUTED, "Stopped"),
    "error": (RED, "Error"),
}

DEFAULT_CONFIG = {
    "api_key": "",
    "reference_id": "",
    "model": "s2.1-pro",
    "latency": "balanced",
    "stt_language": "pl",
    "output_device": "",
    "monitor_device": NO_DEVICE,
    "input_device": DEFAULT_MIC,
    "ptt_hotkey": "f7",
    "stop_hotkey": "f6",
}


class ConfigurationError(Exception):
    pass


def load_config():
    config = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.exists():
        try:
            config.update(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            pass
    return {key: config[key] for key in DEFAULT_CONFIG}


def save_config(config):
    CONFIG_PATH.write_text(json.dumps(config, indent=2, ensure_ascii=False), encoding="utf-8")


def list_devices(channels_key):
    hostapis = sd.query_hostapis()
    devices = {}
    for index, device in enumerate(sd.query_devices()):
        if device[channels_key] > 0:
            label = f"{device['name']} [{hostapis[device['hostapi']]['name']}]"
            devices.setdefault(label, index)
    return devices


def find_vb_cable(labels):
    cables = [label for label in labels if "CABLE Input" in label]
    preferred = [label for label in cables if label.endswith("[MME]")]
    return (preferred or cables or [""])[0]


def pcm_to_wav(pcm, sample_rate):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(BYTES_PER_SAMPLE)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return buffer.getvalue()


def elapsed_ms(since):
    return int((time.perf_counter() - since) * 1000)


def describe_error(error):
    if isinstance(error, ConfigurationError):
        return str(error)
    if isinstance(error, fish_errors.AuthenticationError):
        return "Invalid API key (401). Check the key in your Fish Audio account."
    if isinstance(error, fish_errors.PermissionError):
        return "Access denied (403). Your plan may not allow this model or voice."
    if isinstance(error, fish_errors.NotFoundError):
        return "Voice not found (404). Check the Reference ID."
    if isinstance(error, fish_errors.RateLimitError):
        return "Rate limit exceeded (429). Wait a moment and try again."
    if isinstance(error, fish_errors.ServerError):
        return f"Fish Audio server error ({error.status}). Try again later."
    if isinstance(error, fish_errors.APIError):
        if error.status == 402:
            return "Insufficient account balance (402). Top up your Fish Audio credits."
        return f"Fish Audio API error ({error.status}): {error.message}"
    if isinstance(error, httpx.TimeoutException):
        return "Fish Audio request timed out. Check your internet connection."
    if isinstance(error, httpx.TransportError):
        return "Cannot connect to Fish Audio. Check your internet connection."
    if isinstance(error, sd.PortAudioError):
        return f"Audio device error: {error}"
    return f"Unexpected error: {type(error).__name__}: {error}"


class FishConnection:
    def __init__(self):
        self.http = httpx.Client(
            base_url=API_URL,
            timeout=httpx.Timeout(240, connect=10),
            limits=httpx.Limits(keepalive_expiry=KEEPALIVE_SECONDS),
        )
        self.client = None
        self.last_warm = 0.0

    def configure(self, api_key):
        self.client = FishAudio(api_key=api_key, httpx_client=self.http) if api_key else None

    def require_client(self):
        if self.client is None:
            raise ConfigurationError("API key is missing. Enter it in Settings and click Save & Apply.")
        return self.client

    def warm(self):
        now = time.monotonic()
        if now - self.last_warm < WARM_THROTTLE_SECONDS:
            return
        self.last_warm = now
        threading.Thread(target=self._warm, daemon=True).start()

    def _warm(self):
        try:
            self.http.head("/")
        except httpx.HTTPError:
            pass

    def close(self):
        self.http.close()


class OutputDevice:
    def __init__(self, label, index, on_error):
        self.label = label
        self.on_error = on_error
        self.closed = False
        self.queue = queue.Queue()
        self.stream = sd.RawOutputStream(
            samplerate=SAMPLE_RATE, channels=1, dtype="int16", device=index, latency="low"
        )
        self.stream.start()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while True:
            data = self.queue.get()
            try:
                if data is None:
                    return
                self.stream.write(data)
            except sd.PortAudioError as error:
                self.on_error(f"Playback failed on '{self.label}': {error}")
            finally:
                self.queue.task_done()

    def write(self, data):
        if not self.closed:
            self.queue.put(data)

    def clear(self):
        while True:
            try:
                self.queue.get_nowait()
                self.queue.task_done()
            except queue.Empty:
                return

    def is_busy(self):
        return not self.closed and self.queue.unfinished_tasks > 0

    def close(self):
        self.closed = True
        self.clear()
        self.queue.put(None)
        self.thread.join(timeout=2)
        try:
            self.stream.stop()
            self.stream.close()
        except sd.PortAudioError:
            pass


class Speaker:
    def __init__(self, connection, emit):
        self.connection = connection
        self.emit = emit
        self.reference_id = None
        self.model = DEFAULT_CONFIG["model"]
        self.latency = DEFAULT_CONFIG["latency"]
        self.outputs = []
        self.jobs = queue.Queue()
        self.stop_event = threading.Event()
        threading.Thread(target=self._run, daemon=True).start()

    def configure(self, reference_id, model, latency):
        self.reference_id = reference_id or None
        self.model = model
        self.latency = latency

    def set_outputs(self, devices):
        self.stop()
        old_outputs, self.outputs = self.outputs, []
        for output in old_outputs:
            output.close()
        opened = []
        try:
            for label, index in devices:
                opened.append(OutputDevice(label, index, lambda message: self.emit("state", "error", message)))
        except sd.PortAudioError as error:
            for output in opened:
                output.close()
            raise ConfigurationError(f"Cannot open audio device '{label}': {error}") from error
        self.outputs = opened

    def say(self, text, started_at=None, asr_ms=None):
        text = text.strip()
        if text:
            self.jobs.put((text, started_at or time.perf_counter(), asr_ms))

    def stop(self):
        self.stop_event.set()
        while True:
            try:
                self.jobs.get_nowait()
            except queue.Empty:
                break
        for output in self.outputs:
            output.clear()

    def _run(self):
        while True:
            job = self.jobs.get()
            self.stop_event.clear()
            try:
                self._speak(*job)
                if self.stop_event.is_set():
                    self.emit("state", "stopped", "Playback stopped.")
                else:
                    self.emit("state", "ready", "")
            except Exception as error:
                self.emit("state", "error", describe_error(error))

    def _speak(self, text, started_at, asr_ms):
        client = self.connection.require_client()
        outputs = self.outputs
        if not outputs:
            raise ConfigurationError("No output device is open. Select a device in Settings and click Save & Apply.")
        self.emit("state", "generating", text)
        requested_at = time.perf_counter()
        stream = client.tts.stream(
            text=text,
            reference_id=self.reference_id,
            format="pcm",
            latency=self.latency,
            model=self.model,
            config=TTSConfig(format="pcm", sample_rate=SAMPLE_RATE),
        )
        buffer = b""
        tts_ms = None
        started = False
        for chunk in stream:
            if self.stop_event.is_set():
                return
            if tts_ms is None:
                tts_ms = elapsed_ms(requested_at)
            buffer += chunk
            if not started and len(buffer) < PREBUFFER_BYTES:
                continue
            if not started:
                started = True
                self._report_playback(text, asr_ms, tts_ms, started_at)
            buffer = self._write_aligned(outputs, buffer)
        if not started and tts_ms is not None:
            self._report_playback(text, asr_ms, tts_ms, started_at)
        self._write_aligned(outputs, buffer)
        while any(output.is_busy() for output in outputs) and not self.stop_event.is_set():
            time.sleep(0.02)

    def _report_playback(self, text, asr_ms, tts_ms, started_at):
        self.emit("timing", {"asr": asr_ms, "tts": tts_ms, "total": elapsed_ms(started_at)})
        self.emit("state", "playing", text)

    def _write_aligned(self, outputs, buffer):
        usable = len(buffer) - len(buffer) % BYTES_PER_SAMPLE
        if usable:
            for output in outputs:
                output.write(buffer[:usable])
        return buffer[usable:]


class Recorder:
    def __init__(self, device_index):
        self.lock = threading.Lock()
        self.preroll = collections.deque(maxlen=PREROLL_BLOCKS)
        self.frames = None
        self.stream = sd.RawInputStream(
            samplerate=MIC_SAMPLE_RATE,
            channels=1,
            dtype="int16",
            device=device_index,
            blocksize=MIC_BLOCK_FRAMES,
            callback=self._callback,
        )
        self.stream.start()

    def _callback(self, data, _frames, _time_info, _status):
        block = bytes(data)
        with self.lock:
            if self.frames is None:
                self.preroll.append(block)
            else:
                self.frames.append(block)

    @property
    def recording(self):
        return self.frames is not None

    def start(self):
        with self.lock:
            if self.frames is None:
                self.frames = list(self.preroll)
                self.preroll.clear()

    def stop(self):
        with self.lock:
            frames, self.frames = self.frames, None
        return b"".join(frames or [])

    def close(self):
        try:
            self.stream.stop()
            self.stream.close()
        except sd.PortAudioError:
            pass


class Transcriber:
    def __init__(self, connection, emit):
        self.connection = connection
        self.emit = emit
        self.language = None
        self.clips = queue.Queue()
        threading.Thread(target=self._run, daemon=True).start()

    def configure(self, language):
        self.language = language or None

    def submit(self, pcm, released_at):
        self.clips.put((pcm, released_at))

    def _run(self):
        while True:
            pcm, released_at = self.clips.get()
            try:
                self._transcribe(pcm, released_at)
            except Exception as error:
                self.emit("state", "error", describe_error(error))

    def _transcribe(self, pcm, released_at):
        client = self.connection.require_client()
        self.emit("state", "transcribing", "")
        requested_at = time.perf_counter()
        options = {"language": self.language} if self.language else {}
        result = client.asr.transcribe(audio=pcm_to_wav(pcm, MIC_SAMPLE_RATE), include_timestamps=False, **options)
        asr_ms = elapsed_ms(requested_at)
        text = result.text.strip()
        if text:
            self.emit("transcript", text, released_at, asr_ms)
        else:
            self.emit("state", "error", "No speech recognized.")


class MetricTile(ctk.CTkFrame):
    def __init__(self, master, title):
        super().__init__(master, fg_color=CARD, corner_radius=14, border_width=1, border_color=BORDER)
        ctk.CTkLabel(self, text=title, text_color=MUTED, font=ctk.CTkFont(size=12)).pack(
            anchor="w", padx=14, pady=(12, 0)
        )
        self.value = ctk.CTkLabel(self, text="—", text_color=TEXT, font=ctk.CTkFont(size=24, weight="bold"))
        self.value.pack(anchor="w", padx=14, pady=(0, 12))

    def set(self, milliseconds):
        self.value.configure(text="—" if milliseconds is None else f"{milliseconds} ms")


class App(ctk.CTk):
    def __init__(self):
        super().__init__(fg_color=BG)
        self.title("Fish Voice")
        self.geometry("620x700")
        self.minsize(560, 640)
        self.events = queue.Queue()
        self.config_data = load_config()
        self.devices = {}
        self.input_devices = {}
        self.recorder = None
        self.ptt_hooks = []
        emit = lambda *event: self.events.put(event)
        self.connection = FishConnection()
        self.speaker = Speaker(self.connection, emit)
        self.transcriber = Transcriber(self.connection, emit)
        self._build_ui()
        self._refresh_devices()
        self._apply(save=False)
        self.after(50, self._process_events)
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_ui(self):
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)

        header = ctk.CTkFrame(self, fg_color="transparent")
        header.grid(row=0, column=0, sticky="ew", padx=20, pady=(18, 6))
        header.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(header, text="Fish Voice", text_color=TEXT, font=ctk.CTkFont(size=22, weight="bold")).grid(
            row=0, column=0, sticky="w"
        )
        ctk.CTkLabel(header, text="Speak or type — heard in your Fish Audio voice", text_color=MUTED).grid(
            row=1, column=0, sticky="w"
        )
        pill = ctk.CTkFrame(header, fg_color=CARD, corner_radius=20, border_width=1, border_color=BORDER)
        pill.grid(row=0, column=1, rowspan=2, sticky="e")
        self.state_dot = ctk.CTkLabel(pill, text="●", font=ctk.CTkFont(size=16))
        self.state_dot.pack(side="left", padx=(14, 6), pady=6)
        self.state_text = ctk.CTkLabel(pill, text="", text_color=TEXT, font=ctk.CTkFont(size=13, weight="bold"))
        self.state_text.pack(side="left", padx=(0, 14), pady=6)

        tabs = ctk.CTkTabview(
            self,
            fg_color=BG,
            segmented_button_fg_color=CARD,
            segmented_button_selected_color=ACCENT,
            segmented_button_selected_hover_color=ACCENT_HOVER,
            segmented_button_unselected_color=CARD,
            segmented_button_unselected_hover_color=CARD_HOVER,
        )
        tabs.grid(row=1, column=0, sticky="nsew", padx=14)
        self._build_talk_tab(tabs.add("Talk"))
        self._build_settings_tab(tabs.add("Settings"))

        self.message_label = ctk.CTkLabel(self, text="", anchor="w", justify="left", wraplength=580)
        self.message_label.grid(row=2, column=0, sticky="ew", padx=22, pady=(4, 14))

    def _build_talk_tab(self, tab):
        tab.grid_columnconfigure(0, weight=1)

        self.ptt_button = ctk.CTkButton(
            tab,
            text="",
            height=150,
            corner_radius=24,
            fg_color=CARD,
            hover_color=CARD_HOVER,
            border_width=2,
            border_color=BORDER,
            text_color=TEXT,
            font=ctk.CTkFont(size=18, weight="bold"),
        )
        self.ptt_button.grid(row=0, column=0, sticky="ew", pady=(8, 16))
        self.ptt_button.bind("<ButtonPress-1>", lambda _event: self._start_recording())
        self.ptt_button.bind("<ButtonRelease-1>", lambda _event: self._finish_recording())

        composer = ctk.CTkFrame(tab, fg_color=CARD, corner_radius=16, border_width=1, border_color=BORDER)
        composer.grid(row=1, column=0, sticky="ew")
        composer.grid_columnconfigure(0, weight=1)
        self.text_entry = ctk.CTkEntry(
            composer,
            placeholder_text="Type a message and press Enter…",
            height=46,
            border_width=0,
            fg_color=CARD,
            text_color=TEXT,
            font=ctk.CTkFont(size=15),
        )
        self.text_entry.grid(row=0, column=0, sticky="ew", padx=(10, 6), pady=8)
        self.text_entry.bind("<Return>", self._on_enter)
        self.text_entry.bind("<Key>", lambda _event: self.connection.warm())
        ctk.CTkButton(
            composer, text="Send", width=76, height=38, corner_radius=12,
            fg_color=ACCENT, hover_color=ACCENT_HOVER, command=self._send_typed,
        ).grid(row=0, column=1, padx=4, pady=8)
        self.stop_button = ctk.CTkButton(
            composer, text="Stop", width=76, height=38, corner_radius=12,
            fg_color="transparent", hover_color=CARD_HOVER, border_width=1, border_color=RED,
            text_color=RED, command=self.speaker.stop,
        )
        self.stop_button.grid(row=0, column=2, padx=(4, 10), pady=8)

        ctk.CTkLabel(tab, text="LATENCY · LAST MESSAGE", text_color=MUTED, font=ctk.CTkFont(size=11, weight="bold")).grid(
            row=2, column=0, sticky="w", pady=(20, 6), padx=4
        )
        metrics = ctk.CTkFrame(tab, fg_color="transparent")
        metrics.grid(row=3, column=0, sticky="ew")
        metrics.grid_columnconfigure((0, 1, 2), weight=1, uniform="metric")
        self.asr_tile = MetricTile(metrics, "Speech → text")
        self.asr_tile.grid(row=0, column=0, sticky="ew", padx=(0, 6))
        self.tts_tile = MetricTile(metrics, "TTS first byte")
        self.tts_tile.grid(row=0, column=1, sticky="ew", padx=6)
        self.total_tile = MetricTile(metrics, "Total to audio")
        self.total_tile.grid(row=0, column=2, sticky="ew", padx=(6, 0))

        self.last_label = ctk.CTkLabel(tab, text="", text_color=MUTED, anchor="w", justify="left", wraplength=560)
        self.last_label.grid(row=4, column=0, sticky="ew", pady=(14, 0), padx=4)

    def _build_settings_tab(self, tab):
        ctk.CTkButton(
            tab, text="Save & Apply", height=44, corner_radius=12,
            fg_color=ACCENT, hover_color=ACCENT_HOVER, font=ctk.CTkFont(size=14, weight="bold"),
            command=self._apply,
        ).pack(side="bottom", fill="x", padx=4, pady=(8, 4))
        scroll = ctk.CTkScrollableFrame(tab, fg_color="transparent")
        scroll.pack(fill="both", expand=True)
        scroll.grid_columnconfigure((0, 1), weight=1)
        row = 0

        def section(title):
            nonlocal row
            ctk.CTkLabel(scroll, text=title, text_color=MUTED, font=ctk.CTkFont(size=11, weight="bold")).grid(
                row=row, column=0, columnspan=2, sticky="w", padx=4, pady=(14, 4)
            )
            row += 1

        def field(label, widget, column=0, span=2):
            nonlocal row
            ctk.CTkLabel(scroll, text=label, text_color=TEXT, font=ctk.CTkFont(size=13)).grid(
                row=row, column=column, columnspan=span, sticky="w", padx=4
            )
            widget.grid(row=row + 1, column=column, columnspan=span, sticky="ew", padx=4, pady=(2, 8))
            if column + span >= 2:
                row += 2

        entry_style = {"height": 38, "corner_radius": 10, "border_color": BORDER, "fg_color": CARD}
        combo_style = {
            "height": 38, "corner_radius": 10, "border_color": BORDER, "fg_color": CARD,
            "button_color": BORDER, "button_hover_color": CARD_HOVER, "state": "readonly",
        }

        section("FISH AUDIO")
        key_row = ctk.CTkFrame(scroll, fg_color="transparent")
        key_row.grid_columnconfigure(0, weight=1)
        self.api_key_entry = ctk.CTkEntry(key_row, show="•", **entry_style)
        self.api_key_entry.grid(row=0, column=0, sticky="ew")
        self.api_key_entry.insert(0, self.config_data["api_key"])
        self.key_toggle = ctk.CTkButton(
            key_row, text="Show", width=64, height=38, corner_radius=10,
            fg_color=CARD, hover_color=CARD_HOVER, border_width=1, border_color=BORDER,
            command=self._toggle_key,
        )
        self.key_toggle.grid(row=0, column=1, padx=(8, 0))
        field("API key", key_row)
        self.reference_entry = ctk.CTkEntry(scroll, placeholder_text="Voice model ID from fish.audio", **entry_style)
        if self.config_data["reference_id"]:
            self.reference_entry.insert(0, self.config_data["reference_id"])
        field("Reference ID (voice)", self.reference_entry)

        section("AUDIO")
        self.output_combo = ctk.CTkComboBox(scroll, values=[], **combo_style)
        field("Output — game mic (CABLE Input)", self.output_combo)
        self.monitor_combo = ctk.CTkComboBox(scroll, values=[], **combo_style)
        field("Monitor — headphones", self.monitor_combo)
        self.mic_combo = ctk.CTkComboBox(scroll, values=[], **combo_style)
        field("Microphone", self.mic_combo)
        ctk.CTkButton(
            scroll, text="Refresh devices", height=34, corner_radius=10,
            fg_color=CARD, hover_color=CARD_HOVER, border_width=1, border_color=BORDER,
            command=self._refresh_devices,
        ).grid(row=row, column=0, sticky="w", padx=4, pady=(0, 4))
        row += 1

        section("HOTKEYS")
        self.ptt_hotkey_entry = ctk.CTkEntry(scroll, **entry_style)
        self.ptt_hotkey_entry.insert(0, self.config_data["ptt_hotkey"])
        field("Push-to-talk (hold)", self.ptt_hotkey_entry, column=0, span=1)
        self.stop_hotkey_entry = ctk.CTkEntry(scroll, **entry_style)
        self.stop_hotkey_entry.insert(0, self.config_data["stop_hotkey"])
        field("Stop", self.stop_hotkey_entry, column=1, span=1)

    def _toggle_key(self):
        hidden = self.api_key_entry.cget("show") == "•"
        self.api_key_entry.configure(show="" if hidden else "•")
        self.key_toggle.configure(text="Hide" if hidden else "Show")

    def _refresh_devices(self):
        try:
            self.devices = list_devices("max_output_channels")
            self.input_devices = list_devices("max_input_channels")
        except sd.PortAudioError as error:
            self._set_state("error", f"Cannot list audio devices: {error}")
            self.devices, self.input_devices = {}, {}

        mics = [label for label in self.input_devices if "CABLE Output" not in label]
        self.mic_combo.configure(values=[DEFAULT_MIC] + mics)
        saved_mic = self.config_data["input_device"]
        self.mic_combo.set(saved_mic if saved_mic in self.input_devices else DEFAULT_MIC)

        labels = list(self.devices)
        self.output_combo.configure(values=labels)
        self.monitor_combo.configure(values=[NO_DEVICE] + labels)
        saved_output = self.config_data["output_device"]
        output = saved_output if saved_output in self.devices else find_vb_cable(labels)
        self.output_combo.set(output)
        saved_monitor = self.config_data["monitor_device"]
        self.monitor_combo.set(saved_monitor if saved_monitor in self.devices else NO_DEVICE)

        if not output:
            self._set_state(
                "error",
                f"VB-CABLE ('CABLE Input') not found. Install it from {VB_CABLE_URL}, "
                "restart Windows, then click Refresh devices — or pick another output.",
            )

    def _collect_config(self):
        self.config_data.update(
            {
                "api_key": self.api_key_entry.get().strip(),
                "reference_id": self.reference_entry.get().strip(),
                "output_device": self.output_combo.get(),
                "monitor_device": self.monitor_combo.get(),
                "input_device": self.mic_combo.get(),
                "ptt_hotkey": self.ptt_hotkey_entry.get().strip().lower(),
                "stop_hotkey": self.stop_hotkey_entry.get().strip().lower(),
            }
        )

    def _apply(self, save=True):
        self._collect_config()
        config = self.config_data
        if save:
            try:
                save_config(config)
            except OSError as error:
                self._set_state("error", f"Cannot save config.json: {error}")
                return

        self.connection.configure(config["api_key"])
        self.speaker.configure(config["reference_id"], config["model"], config["latency"])
        self.transcriber.configure(config["stt_language"])
        problems = []

        selected = [config["output_device"]]
        if config["monitor_device"] not in (NO_DEVICE, config["output_device"]):
            selected.append(config["monitor_device"])
        devices = [(label, self.devices[label]) for label in selected if label in self.devices]
        try:
            self.speaker.set_outputs(devices)
        except ConfigurationError as error:
            problems.append(str(error))

        mic_error = self._open_microphone()
        if mic_error:
            problems.append(mic_error)
        problems.extend(self._register_hotkeys())
        if not config["api_key"]:
            problems.append("API key is missing — add it in Settings.")
        if not devices:
            problems.append("No output device selected.")

        self._update_ptt_button()
        if problems:
            self._set_state("error", " ".join(problems))
        else:
            self._set_state("ready", "Settings saved." if save else "")
            self.connection.warm()

    def _open_microphone(self):
        if self.recorder:
            self.recorder.close()
            self.recorder = None
        label = self.config_data["input_device"]
        try:
            self.recorder = Recorder(self.input_devices.get(label))
        except sd.PortAudioError as error:
            return f"Cannot open microphone '{label}': {error}."
        return None

    def _unhook_all(self):
        try:
            keyboard.unhook_all_hotkeys()
        except (AttributeError, KeyError):
            pass
        for hook in self.ptt_hooks:
            try:
                keyboard.unhook(hook)
            except (KeyError, ValueError):
                pass
        self.ptt_hooks = []

    def _register_hotkeys(self):
        errors = []
        self._unhook_all()
        ptt = self.config_data["ptt_hotkey"]
        if ptt:
            try:
                self.ptt_hooks = [
                    keyboard.on_press_key(ptt, lambda _event: self.events.put(("ptt_down",))),
                    keyboard.on_release_key(ptt, lambda _event: self.events.put(("ptt_up",))),
                ]
            except (ValueError, ImportError, OSError) as error:
                errors.append(f"Push-to-talk key '{ptt}' failed (use a single key, e.g. f7): {error}.")
        stop = self.config_data["stop_hotkey"]
        if stop:
            try:
                keyboard.add_hotkey(stop, lambda: self.events.put(("stop",)))
            except (ValueError, ImportError, OSError) as error:
                errors.append(f"Stop hotkey '{stop}' failed: {error}.")
        return errors

    def _on_enter(self, _event):
        self._send_typed()
        return "break"

    def _send_typed(self):
        text = self.text_entry.get()
        if text.strip():
            self.speaker.say(text)
            self.last_label.configure(text=f"Last: {text.strip()}")
        self.text_entry.delete(0, "end")

    def _start_recording(self):
        if not self.recorder:
            self._set_state("error", "Microphone is not open. Select it in Settings and click Save & Apply.")
            return
        if not self.recorder.recording:
            self.connection.warm()
            self.recorder.start()
            self._set_state("recording", "")

    def _finish_recording(self):
        if not self.recorder or not self.recorder.recording:
            return
        released_at = time.perf_counter()
        pcm = self.recorder.stop()
        if len(pcm) < MIN_RECORDING_SECONDS * MIC_SAMPLE_RATE * BYTES_PER_SAMPLE:
            self._set_state("error", "Recording too short — hold the key while speaking.")
            return
        self.transcriber.submit(pcm, released_at)

    def _say_transcript(self, text, released_at, asr_ms):
        self.last_label.configure(text=f"Heard: {text}")
        self.speaker.say(text, started_at=released_at, asr_ms=asr_ms)

    def _process_events(self):
        while True:
            try:
                event = self.events.get_nowait()
            except queue.Empty:
                break
            kind = event[0]
            if kind == "state":
                self._set_state(event[1], event[2])
            elif kind == "timing":
                self._show_timing(event[1])
            elif kind == "transcript":
                self._say_transcript(*event[1:])
            elif kind == "ptt_down":
                self._start_recording()
            elif kind == "ptt_up":
                self._finish_recording()
            elif kind == "stop":
                self.speaker.stop()
        self.after(50, self._process_events)

    def _show_timing(self, timing):
        self.asr_tile.set(timing["asr"])
        self.tts_tile.set(timing["tts"])
        self.total_tile.set(timing["total"])

    def _update_ptt_button(self, recording=False):
        key = (self.config_data["ptt_hotkey"] or "mouse").upper()
        if recording:
            self.ptt_button.configure(
                text="● Recording…\nrelease to send", fg_color=RED, hover_color=RED_HOVER, border_color=RED
            )
        else:
            self.ptt_button.configure(
                text=f"🎙  Hold {key} to talk\nor hold this button",
                fg_color=CARD, hover_color=CARD_HOVER, border_color=BORDER,
            )

    def _set_state(self, state, message):
        color, label = STATE_STYLES[state]
        self.state_dot.configure(text_color=color)
        self.state_text.configure(text=label)
        self._update_ptt_button(recording=state == "recording")
        if state in ("generating", "playing"):
            message = f"“{message}”"
        self.message_label.configure(text=message, text_color=RED if state == "error" else MUTED)

    def _on_close(self):
        self._unhook_all()
        if self.recorder:
            self.recorder.close()
        self.speaker.stop()
        for output in self.speaker.outputs:
            output.close()
        self.connection.close()
        self.destroy()


if __name__ == "__main__":
    ctk.set_appearance_mode("dark")
    App().mainloop()
