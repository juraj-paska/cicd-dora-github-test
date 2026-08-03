FROM python:3.13-slim

WORKDIR /app

# Install dependencies first for better layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && opentelemetry-bootstrap --action=install

# Copy application code
COPY app.py .

# Pipeline run number, passed in at build time and exposed to the app at
# runtime (rendered into the page heading). Empty for plain local builds.
ARG RUN_NUMBER=""
ENV RUN_NUMBER=$RUN_NUMBER

# Run as a non-root user
RUN useradd --create-home --uid 1000 appuser
USER appuser

# Port is configurable via $PORT (default 8080) so the same image can run
# as multiple containers in one pod on different ports.
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen(f\"http://localhost:{os.environ.get('PORT','8080')}/health\").status==200 else 1)"

# SolarWinds APM via OpenTelemetry auto-instrumentation.
# opentelemetry-instrument wraps gunicorn and traces the Flask app.
# 2 workers is plenty for this tiny app; bind to all interfaces on $PORT.
CMD ["sh", "-c", "exec opentelemetry-instrument gunicorn --bind 0.0.0.0:${PORT:-8080} --workers 2 app:app"]
