# MinerU publishes no image. This one serves its API with the small layout, OCR and table
# models baked in, and leaves the VLM to an OpenAI-compatible server elsewhere.
FROM docker.io/library/python:3.13.16-slim-trixie@sha256:cf50a4f6ac4f026458b08d5222023d700ac806410dff5e9ca8728fa44f2b850f

# renovate: datasource=pypi depName=mineru
ARG MINERU_VERSION=4.0.12

ENV MINERU_HOME=/opt/mineru \
    HOME=/tmp \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN pip install "mineru==${MINERU_VERSION}"

# The pod has no internet: the models must be in the image, and the hub must never be asked.
RUN mineru-kit models download MinerU-4_models_onnx --source huggingface \
    && rm -rf /opt/mineru/models/.locks /opt/mineru/models/*/.cache /tmp/.cache
ENV HF_HUB_OFFLINE=1

USER 1000:1000
EXPOSE 8000
ENTRYPOINT ["mineru-kit", "api-server", "--host", "0.0.0.0", "--port", "8000"]
