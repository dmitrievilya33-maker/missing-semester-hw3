FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --uid 10001 --create-home appuser \
    && mkdir /data \
    && chown appuser:appuser /data
COPY app/app.py .
USER 10001:10001
EXPOSE 8000
STOPSIGNAL SIGINT
CMD ["python", "app.py"]
