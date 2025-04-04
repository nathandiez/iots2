# web backend app.py
from flask import Flask, jsonify, request
from flask_cors import CORS
import psycopg2
import os
from datetime import datetime, timedelta
from functools import wraps

app = Flask(__name__)
CORS(app)

def require_api_key(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        api_key = request.headers.get('X-API-Key')
        if api_key != os.getenv("API_KEY"):
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated_function

def get_db_connection():
    return psycopg2.connect(
        dbname=os.getenv("POSTGRES_DB", "iotdb"),
        user=os.getenv("POSTGRES_USER", "iotuser"),
        password=os.getenv("POSTGRES_PASSWORD", "iotpass"),
        host=os.getenv("POSTGRES_HOST", "timescaledb"),
        port=os.getenv("POSTGRES_PORT", "5432")
    )

@app.route('/health', methods=['GET'])
def health_check():
    try:
        # Test DB connection
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                return jsonify({"status": "healthy"})
    except Exception as e:
        return jsonify({"status": "unhealthy", "reason": str(e)}), 500

@app.route('/api/devices', methods=['GET'])
@require_api_key
def get_devices():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT DISTINCT device_id FROM sensor_data ORDER BY device_id")
            devices = [row[0] for row in cur.fetchall()]
            return jsonify(devices)

@app.route('/api/sensor-data', methods=['GET'])
@require_api_key
def get_sensor_data():
    device_id = request.args.get('device_id')
    # Default to 1 hour if not specified, to fetch recent events including the test one
    hours = int(request.args.get('hours', 1)) 

    # <<< MODIFIED: Added event_type to SELECT list >>>
    query = """
        SELECT time, device_id, event_type, temperature, humidity, pressure, motion, switch
        FROM sensor_data
        WHERE time > NOW() - interval '%s hours'
    """
    params = [hours]

    if device_id:
        query += " AND device_id = %s"
        params.append(device_id)

    query += " ORDER BY time DESC"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(query, params)
            # This part dynamically gets column names, so it will include event_type
            columns = [desc[0] for desc in cur.description]
            results = []
            for row in cur.fetchall():
                results.append(dict(zip(columns, row)))
            return jsonify(results)

@app.route('/api/stats', methods=['GET'])
@require_api_key
def get_stats():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT 
                    device_id,
                    COUNT(*) as readings,
                    AVG(temperature) as avg_temp,
                    AVG(humidity) as avg_humidity,
                    AVG(pressure) as avg_pressure
                FROM sensor_data
                WHERE time > NOW() - interval '24 hours'
                GROUP BY device_id
                ORDER BY device_id
            """)
            columns = [desc[0] for desc in cur.description]
            results = []
            for row in cur.fetchall():
                results.append(dict(zip(columns, row)))
            return jsonify(results)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)