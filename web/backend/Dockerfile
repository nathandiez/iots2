FROM python:3.9-slim-buster
RUN groupadd -r appgroup && useradd -r -g appgroup appuser
WORKDIR /app
COPY app.py .
RUN apt-get update && \
    apt-get install -y gcc python3-dev libpq-dev && \
    pip install flask flask-cors psycopg2 && \
    apt-get remove -y gcc python3-dev && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /app/logs && \
    chown -R appuser:appgroup /app
USER appuser
EXPOSE 5000
CMD ["python", "app.py"]