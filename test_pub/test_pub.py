#!/usr/bin/env python3
import os
import ssl
import paho.mqtt.client as mqtt
import time
import json
import random
import logging
import sys
import pytz
from datetime import datetime

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

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        logger.info("Connected successfully to MQTT broker")
    else:
        logger.error(f"Failed to connect, return code: {rc}")

def on_disconnect(client, userdata, rc):
    logger.warning(f"Disconnected with result code: {rc}")
    if rc != 0:
        logger.warning("Unexpected disconnect. Will auto-reconnect")

def generate_sensor_data():
    # Device selection
    device_id = random.choice(['kitchen1', 'loft2', 'basement3'])
    
    # Temperature (F) - reasonable indoor temps between 65-80°F
    temp_f = round(random.uniform(65, 80), 1)
    
    # Humidity between 30-60%
    humidity = round(random.uniform(30, 60), 1)
    
    # Barometric pressure (typical range 29.70-30.20 inHg)
    pressure = round(random.uniform(29.70, 30.20), 2)
    
    # Motion and switch states
    motion = random.choice(['HIGH', 'LOW'])
    switch = random.choice(['HIGH', 'LOW'])
    
    # Get current time in Eastern timezone
    eastern = pytz.timezone('America/New_York')
    eastern_time = datetime.now(eastern)
    timestamp = eastern_time.strftime('%Y-%m-%d %H:%M:%S')
    
    return {
        "device_id": device_id,
        "temperature": temp_f,
        "humidity": humidity,
        "pressure": pressure,
        "motion": motion,
        "switch": switch,
        "timestamp": timestamp
    }

# Create MQTT client instance
client = mqtt.Client()
client.on_connect = on_connect
client.on_disconnect = on_disconnect

# Configure TLS
client.tls_set(ca_certs="/mosquitto/certs/ca.crt", tls_version=ssl.PROTOCOL_TLSv1_2)
#client.tls_insecure_set(True)  # For testing only; remove in production

# Enable automatic reconnection
client.reconnect_delay_set(min_delay=1, max_delay=30)

try:
    logger.info("Attempting to connect to broker...")
    # Read the broker address from the environment variable (default to "mqtt")
    broker_address = os.getenv("MQTT_BROKER", "mqtt")
    client.connect(broker_address, 8883, 60)
    client.loop_start()

    # Wait for connection to establish
    time.sleep(2)

    while True:
        try:
            if not client.is_connected():
                logger.warning("Not connected, waiting for reconnection...")
                time.sleep(1)
                continue

            data = generate_sensor_data()
            result = client.publish("home/sensors/test", json.dumps(data))
            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                logger.info(f"Message published successfully: {data}")
            else:
                logger.error(f"Failed to publish message, error code: {result.rc}")
            
            time.sleep(5)
            
        except KeyboardInterrupt:
            logger.info("Stopping publisher...")
            break
        except Exception as e:
            logger.error(f"Error in publish loop: {str(e)}")
            time.sleep(5)

except Exception as e:
    logger.error(f"Error setting up MQTT client: {str(e)}")

finally:
    logger.info("Cleaning up...")
    client.loop_stop()
    client.disconnect()
