#!/usr/bin/env python3
import paho.mqtt.client as mqtt
import time
import os
import sys
import logging
import pytz
import json
import psycopg2
import ssl
from datetime import datetime
# Add Prometheus client import
from prometheus_client import start_http_server, Counter, Gauge, Histogram
import threading

# Force unbuffered output
sys.stdout.reconfigure(line_buffering=True)

# Configure logging with timezone conversion
class TimezoneFormatter(logging.Formatter):
    def formatTime(self, record, datefmt=None):
        # Convert UTC to Eastern time
        utc_dt = datetime.utcfromtimestamp(record.created)
        eastern_tz = pytz.timezone('America/New_York')
        eastern_dt = utc_dt.replace(tzinfo=pytz.UTC).astimezone(eastern_tz)
        
        if datefmt:
            return eastern_dt.strftime(datefmt)
        return eastern_dt.strftime('%Y-%m-%d %H:%M:%S')

# Set up logging with custom formatter
handler = logging.StreamHandler(sys.stdout)
formatter = TimezoneFormatter('%(asctime)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
logger.addHandler(handler)

# Clear any existing handlers
logger.handlers = []
logger.addHandler(handler)

# Define Prometheus metrics
# Counters - increase each time an event occurs
MESSAGES_RECEIVED = Counter('iot_messages_total', 'Total number of IoT messages received', ['device_id'])
DB_OPERATIONS = Counter('db_operations_total', 'Total number of database operations', ['operation', 'status'])

# Gauges - current value that can go up and down
TEMPERATURE = Gauge('temperature_fahrenheit', 'Temperature in Fahrenheit', ['device_id'])
HUMIDITY = Gauge('humidity_percent', 'Humidity percentage', ['device_id'])
PRESSURE = Gauge('pressure_inhg', 'Barometric pressure in inHg', ['device_id'])

# Histogram - distribution of values
MESSAGE_PROCESSING_TIME = Histogram('message_processing_seconds', 'Time spent processing messages', ['device_id'])

# Start Prometheus HTTP server
def start_metrics_server():
    start_http_server(8000)
    logger.info("Metrics server started on port 8000")

# Database connection
def get_db_connection():
    while True:
        try:
            conn = psycopg2.connect(
                dbname=os.getenv("POSTGRES_DB", "iotdb"),
                user=os.getenv("POSTGRES_USER", "iotuser"),
                password=os.getenv("POSTGRES_PASSWORD", "iotpass"),
                host=os.getenv("POSTGRES_HOST", "timescaledb"),
                port=os.getenv("POSTGRES_PORT", "5432")
            )
            logger.info("Successfully connected to database")
            DB_OPERATIONS.labels(operation='connect', status='success').inc()
            return conn
        except psycopg2.OperationalError as e:
            logger.error(f"Could not connect to database: {e}")
            DB_OPERATIONS.labels(operation='connect', status='failure').inc()
            logger.info("Retrying in 5 seconds...")
            time.sleep(5)

def store_sensor_data(data):
    try:
        with db_conn.cursor() as cur:
            cur.execute("""
                INSERT INTO sensor_data (time, device_id, temperature, humidity, pressure, motion, switch)
                VALUES (%(timestamp)s, %(device_id)s, %(temperature)s, %(humidity)s, %(pressure)s, %(motion)s, %(switch)s)
            """, data)
            db_conn.commit()
            logger.info(f"Stored sensor data for device {data['device_id']}")
            DB_OPERATIONS.labels(operation='insert', status='success').inc()
    except Exception as e:
        logger.error(f"Error storing sensor data: {e}")
        DB_OPERATIONS.labels(operation='insert', status='failure').inc()
        db_conn.rollback()

def on_connect(client, userdata, flags, rc):
    logger.info(f"Connected with result code {rc}")
    logger.info("Subscribing to home/sensors/#")
    client.subscribe("home/sensors/#")

def on_message(client, userdata, msg):
    try:
        start_time = time.time()
        logger.info(f"Received message on {msg.topic}: {msg.payload.decode()}")
        data = json.loads(msg.payload.decode())
        
        # Increment message counter
        device_id = data.get('device_id', 'unknown')
        MESSAGES_RECEIVED.labels(device_id=device_id).inc()
        
        # Update gauges with current values
        TEMPERATURE.labels(device_id=device_id).set(data.get('temperature', 0))
        HUMIDITY.labels(device_id=device_id).set(data.get('humidity', 0))
        PRESSURE.labels(device_id=device_id).set(data.get('pressure', 0))
        
        # Convert timestamp string to timezone-aware datetime in UTC
        eastern = pytz.timezone('America/New_York')
        dt_naive = datetime.strptime(data['timestamp'], '%Y-%m-%d %H:%M:%S')
        data['timestamp'] = eastern.localize(dt_naive).astimezone(pytz.UTC)
        
        # Store data in database
        store_sensor_data(data)
        
        # Record processing time
        processing_time = time.time() - start_time
        MESSAGE_PROCESSING_TIME.labels(device_id=device_id).observe(processing_time)
        
    except json.JSONDecodeError as e:
        logger.error(f"Error decoding JSON: {e}")
        DB_OPERATIONS.labels(operation='parse', status='failure').inc()
    except Exception as e:
        logger.error(f"Error processing message: {e}")
        DB_OPERATIONS.labels(operation='process', status='failure').inc()

def on_subscribe(client, userdata, mid, granted_qos):
    logger.info(f"Subscribed successfully! QoS: {granted_qos}")

def on_disconnect(client, userdata, rc):
    logger.info(f"Disconnected with result code: {rc}")

# Start metrics server in a separate thread
metrics_thread = threading.Thread(target=start_metrics_server, daemon=True)
metrics_thread.start()

# Establish database connection
db_conn = get_db_connection()

# Create client instance with explicit API version
client = mqtt.Client(client_id="", 
                     clean_session=True, 
                     userdata=None, 
                     protocol=mqtt.MQTTv311, 
                     transport="tcp", 
                     reconnect_on_failure=True)

# Assign callback functions
client.on_connect = on_connect
client.on_message = on_message
client.on_subscribe = on_subscribe
client.on_disconnect = on_disconnect

# Set up authentication
username = "iot_service"
password = "na123"  # Replace with password you set
client.username_pw_set(username, password)

# Configure TLS: adjust the CA certificate path as needed
client.tls_set(ca_certs="/mosquitto/certs/ca.crt", tls_version=ssl.PROTOCOL_TLSv1_2)
#client.tls_insecure_set(True)  # For testing only; remove in production

# Get broker address from environment variable, default to mqtt
broker_address = os.getenv("MQTT_BROKER", "mqtt")

logger.info(f"Connecting to broker at {broker_address} over TLS...")

try:
    client.connect(broker_address, 8883, 60)
    client.loop_forever()
except KeyboardInterrupt:
    logger.info("Shutting down...")
    client.disconnect()
    db_conn.close()
except Exception as e:
    logger.error(f"Error occurred: {e}")
    db_conn.close()