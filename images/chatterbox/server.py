import asyncio
import base64
import binascii
import hashlib
import io
import os
import re
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np
import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field

from chatterbox.mtl_tts import SUPPORTED_LANGUAGES, ChatterboxMultilingualTTS

MODEL_DIR = Path(os.environ.get("CHATTERBOX_MODEL_DIR", "/srv/models/chatterbox-multilingual-v3"))
VOICES_DIR = Path(os.environ.get("CHATTERBOX_VOICES_DIR", "/srv/voices"))
DEFAULT_LANGUAGE = os.environ.get("CHATTERBOX_LANGUAGE", "fr")
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
VOICE_NAME = re.compile(r"^[a-z0-9_-]{1,64}$")
SENTENCE_END = re.compile(r"(?<=[.!?…])\s+")
MAX_CHUNK = 280
GAP_SECONDS = 0.12

ENCODERS = {
    "mp3": ("audio/mpeg", ["-f", "mp3", "-b:a", "128k"]),
    "opus": ("audio/ogg", ["-f", "ogg", "-c:a", "libopus", "-b:a", "48k"]),
    "aac": ("audio/aac", ["-f", "adts", "-c:a", "aac", "-b:a", "128k"]),
    "flac": ("audio/flac", ["-f", "flac"]),
}

tts = ChatterboxMultilingualTTS.from_local(MODEL_DIR, DEVICE, t3_model="v3")
voices = {"default": tts.conds}
tts.generate("Bonjour, je suis prête.", language_id=DEFAULT_LANGUAGE)
lock = asyncio.Lock()
app = FastAPI()


class SpeechRequest(BaseModel):
    model: str = "chatterbox"
    input: str = Field(min_length=1, max_length=4096)
    voice: str = "default"
    response_format: str = "mp3"
    speed: float = 1.0
    language: str | None = None
    ref_audio: str | None = None
    exaggeration: float = Field(0.5, ge=0.0, le=2.0)
    cfg_weight: float = Field(0.5, ge=0.0, le=1.0)
    temperature: float = Field(0.8, gt=0.0, le=2.0)


def stored_voices():
    if not VOICES_DIR.is_dir():
        return []
    return sorted(p.stem for p in VOICES_DIR.glob("*.wav") if VOICE_NAME.match(p.stem))


def conditionals_from_file(path):
    tts.prepare_conditionals(str(path))
    return tts.conds


def conditionals_for(request):
    if request.ref_audio:
        try:
            audio = base64.b64decode(request.ref_audio, validate=True)
        except binascii.Error:
            raise HTTPException(400, "ref_audio must be base64")
        key = "ref:" + hashlib.sha256(audio).hexdigest()
        if key not in voices:
            with tempfile.NamedTemporaryFile(suffix=".audio") as f:
                f.write(audio)
                f.flush()
                voices[key] = conditionals_from_file(f.name)
        return voices[key]
    if request.voice in voices:
        return voices[request.voice]
    if not VOICE_NAME.match(request.voice) or not (VOICES_DIR / f"{request.voice}.wav").is_file():
        raise HTTPException(404, f"unknown voice '{request.voice}'")
    voices[request.voice] = conditionals_from_file(VOICES_DIR / f"{request.voice}.wav")
    return voices[request.voice]


def chunks(text):
    pieces = []
    for sentence in SENTENCE_END.split(text.strip()):
        while len(sentence) > MAX_CHUNK:
            cut = sentence.rfind(" ", 0, MAX_CHUNK)
            cut = cut if cut > 0 else MAX_CHUNK
            pieces.append(sentence[:cut])
            sentence = sentence[cut:].lstrip()
        if sentence:
            pieces.append(sentence)
    return pieces


def synthesize(request, language):
    tts.conds = conditionals_for(request)
    gap = np.zeros(int(tts.sr * GAP_SECONDS), dtype=np.float32)
    parts = []
    for piece in chunks(request.input):
        wav = tts.generate(
            piece,
            language_id=language,
            exaggeration=request.exaggeration,
            cfg_weight=request.cfg_weight,
            temperature=request.temperature,
        )
        parts.extend([wav.squeeze(0).cpu().numpy().astype(np.float32), gap])
    return np.concatenate(parts[:-1])


def pcm16(samples):
    return (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()


def encode(samples, fmt):
    pcm = pcm16(samples)
    if fmt == "pcm":
        return "audio/pcm", pcm
    if fmt == "wav":
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(tts.sr)
            w.writeframes(pcm)
        return "audio/wav", buffer.getvalue()
    media_type, args = ENCODERS[fmt]
    result = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-f", "s16le", "-ar", str(tts.sr), "-ac", "1", "-i", "pipe:0", *args, "pipe:1"],
        input=pcm,
        capture_output=True,
        check=True,
    )
    return media_type, result.stdout


@app.get("/health")
def health():
    return {"status": "ok", "device": DEVICE}


@app.get("/v1/audio/voices")
def list_voices():
    return {"voices": ["default", *stored_voices()], "model": "chatterbox"}


@app.post("/v1/audio/speech")
async def speech(request: SpeechRequest):
    language = (request.language or DEFAULT_LANGUAGE).lower()
    if language not in SUPPORTED_LANGUAGES:
        raise HTTPException(400, f"unsupported language '{language}'")
    if request.response_format not in {"pcm", "wav", *ENCODERS}:
        raise HTTPException(400, f"unsupported response_format '{request.response_format}'")
    async with lock:
        samples = await asyncio.to_thread(synthesize, request, language)
    media_type, body = await asyncio.to_thread(encode, samples, request.response_format)
    return Response(content=body, media_type=media_type)
