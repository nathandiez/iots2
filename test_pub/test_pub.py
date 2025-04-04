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
        # Use current time (Thu Apr  3 11:42:00 AM EDT 2025) for format string evaluation
        return eastern_dt.strftime('%Y-%m-%d %H:%M:%S')

# Set up logging with custom formatter
handler = logging.StreamHandler(sys.stdout)
formatter = TimezoneFormatter('%(asctime)s - %(levelname)s - %(message)s', datefmt='%Y-%m-%d %H:%M:%S') # Added datefmt for consistency
handler.setFormatter(formatter)

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
# Clear any existing handlers to avoid duplicate logs if run multiple times
if logger.hasHandlers():
    logger.handlers.clear()
logger.addHandler(handler)
logger.propagate = False # Prevent propagation to root logger if configured

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

    # <<< MODIFIED DICTIONARY >>>
    # Create dictionary including the event_type
    data = {
        "event_type": "heartbeat", # Added event type
        "device_id": device_id,
        "temperature": temp_f,
        "humidity": humidity,
        "pressure": pressure,
        "motion": motion,
        "switch": switch,
        "timestamp": timestamp
    }
    return data

# --- Main Execution ---

# Create MQTT client instance
# Specify client_id for clarity, helps in broker logs
client_id = f"test_pub_{os.getpid()}"
client = mqtt.Client(client_id=client_id)
client.on_connect = on_connect
client.on_disconnect = on_disconnect

# Set up authentication with environment variables
username = os.getenv("MQTT_USERNAME", "test_pub")
password = os.getenv("MQTT_PASSWORD", "")
if not password:
     logger.warning("MQTT_PASSWORD environment variable not set!")
client.username_pw_set(username, password)

# Configure TLS
# Ensure the path to ca.crt inside the container is correct based on volume mount
ca_file_path = "/mosquitto/certs/ca.crt"
if not os.path.exists(ca_file_path):
    logger.error(f"CA certificate file not found at: {ca_file_path}. Check deployment volume mounts.")
    # Exit or handle error appropriately
    sys.exit(1)

try:
    client.tls_set(ca_certs=ca_file_path, tls_version=ssl.PROTOCOL_TLSv1_2)
    logger.info("TLS configured.")
except ssl.SSLError as e:
     logger.error(f"SSL Error during tls_set: {e}. Check CA file content and permissions.")
     sys.exit(1)
except Exception as e:
    logger.error(f"Error configuring TLS: {e}")
    sys.exit(1)


# Enable automatic reconnection
client.reconnect_delay_set(min_delay=1, max_delay=30)

try:
    logger.info("Attempting to connect to broker...")
    # Read the broker address from the environment variable
    broker_address = os.getenv("MQTT_BROKER", "mosquitto.iot-system.svc.cluster.local") # Default to internal k8s service name
    broker_port = 8883 # Using TLS port
    logger.info(f"Connecting to {broker_address}:{broker_port}")
    client.connect(broker_address, broker_port, 60)
    client.loop_start() # Start network loop in background thread

    # Wait briefly for connection to establish before starting publish loop
    time.sleep(3)

    while True:
        try:
            # Use loop_misc() or check is_connected() periodically
            if not client.is_connected():
                logger.warning("Not connected, waiting for auto-reconnection...")
                time.sleep(5) # Wait longer if disconnected
                continue

            data = generate_sensor_data()
            payload = json.dumps(data)
            # Publish to a general test topic, or make it device specific if needed
            topic = "home/sensors/test"
            result = client.publish(topic, payload)

            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                # Use json.dumps for consistent log formatting of dict
                logger.info(f"Message published successfully to {topic}: {payload}")
            else:
                logger.error(f"Failed to publish message to {topic}, error code: {result.rc}")
                # Consider adding a longer delay or reconnect logic on publish failure

            time.sleep(5) # Publishing interval

        except KeyboardInterrupt:
            logger.info("Stopping publisher...")
            break
        except Exception as e:
            logger.error(f"Error in publish loop: {e}", exc_info=True) # Log traceback
            time.sleep(10) # Longer sleep after error

except Exception as e:
    logger.error(f"Error setting up MQTT client or main loop: {e}", exc_info=True)

finally:
    logger.info("Cleaning up...")
    # Stop the network loop and disconnect
    client.loop_stop()
    client.disconnect()
    logger.info("Publisher finished.")