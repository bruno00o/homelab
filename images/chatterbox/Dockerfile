# Chatterbox publishes no image, and its multilingual V3 is not on PyPI. This one serves an
# OpenAI-style speech API on jinbe, started by llama-swap, with the weights mounted from the
# host. PyTorch comes from AMD's nightly index for gfx1151, the only build for that GPU.
FROM docker.io/library/python:3.12.15-slim-bookworm@sha256:57d96f71de145a98e7ceca18ee4ade77bba4103a33a72dfaea026b23625c6bf0

# A nightly: the index can drop it, so the published image is the copy that counts.
ARG ROCM_BUILD=rocm7.13.0a20260513
ARG CHATTERBOX_COMMIT=5de7a54aa4e5e2baadb0182dde554908b48b85c2
ARG PERTH_COMMIT=ff1c8ac55a976971245cdd53c18d6131ca00d993

# MIOPEN_FIND_MODE: the default searches kernels again for every new sentence length.
ENV HOME=/opt/chatterbox \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NUMBA_CACHE_DIR=/tmp/numba \
    HF_HUB_OFFLINE=1 \
    MIOPEN_FIND_MODE=FAST

# torch does not load without libatomic.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libatomic1 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install \
    --index-url https://rocm.nightlies.amd.com/v2/gfx1151/ \
    --extra-index-url https://pypi.org/simple \
    "torch==2.10.0+${ROCM_BUILD}" "torchaudio==2.10.0+${ROCM_BUILD}"

# Chatterbox and Perth go in without their dependencies, which would replace the ROCm torch.
# Everything they need is pinned here instead.
RUN pip install \
    "numpy==1.26.4" \
    "librosa==0.11.0" \
    "s3tokenizer==0.3.0" \
    "transformers==5.2.0" \
    "diffusers==0.29.0" \
    "conformer==0.3.2" \
    "safetensors==0.5.3" \
    "spacy-pkuseg==1.0.1" \
    "pykakasi==2.3.0" \
    "pyloudnorm==0.2.0" \
    "omegaconf==2.3.0" \
    "pydub==0.25.1" \
    "PyYAML==6.0.3" \
    "soundfile==0.14.0" \
    "fastapi==0.142.2" \
    "uvicorn==0.54.0" \
    && pip install --no-deps \
    "https://github.com/resemble-ai/Perth/archive/${PERTH_COMMIT}.tar.gz" \
    "https://github.com/resemble-ai/chatterbox/archive/${CHATTERBOX_COMMIT}.tar.gz"

# pkuseg downloads its model on first use; done here, the container never needs the network.
RUN mkdir -p /opt/chatterbox \
    && python -c "from spacy_pkuseg import pkuseg; pkuseg()" \
    && chown -R 1000:1000 /opt/chatterbox

COPY server.py /app/server.py
WORKDIR /app
USER 1000:1000
ENTRYPOINT ["uvicorn", "server:app", "--host", "127.0.0.1"]
