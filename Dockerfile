FROM python:3.11-slim@sha256:90744cff8f32887f075c47d747a173ff333e9e98801667af93c357fa9f5e28ff AS runtime

LABEL org.opencontainers.image.source="https://github.com/ruizhaoca/canadian-regional-intelligence-snowflake" \
      org.opencontainers.image.description="Statistics Canada acquisition for the Canadian Regional Intelligence MVP"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN useradd --create-home --uid 10001 appuser

COPY pyproject.toml README.md ./
COPY src ./src

RUN python -m pip install --upgrade pip && \
    python -m pip install .

USER appuser

ENTRYPOINT ["python", "-m", "regional_intelligence"]
