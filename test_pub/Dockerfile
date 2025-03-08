FROM python:3.9-slim-buster
RUN groupadd -r appgroup && useradd -r -g appgroup appuser
WORKDIR /app
COPY test_pub.py .
RUN pip install paho-mqtt pytz && \
    mkdir -p /app/logs && \
    chown -R appuser:appgroup /app
USER appuser
CMD ["python", "test_pub.py"]