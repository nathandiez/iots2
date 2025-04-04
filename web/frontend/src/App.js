// web frontend App.js
import React, { useState, useEffect } from 'react';
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer
} from 'recharts';

function App() {
  const [devices, setDevices] = useState([]);
  const [selectedDevice, setSelectedDevice] = useState('');
  const [sensorData, setSensorData] = useState([]);
  const [hours, setHours] = useState(24);
// FORCED REBUILD: 2025-03-09
const apiUrl = '';  // Empty string for relative URLs
const apiKey = 'V2Rvl3oopKZovBFElU83BhbwNqr6WaAd';  // API key for authentication

  useEffect(() => {
    fetch(`${apiUrl}/api/devices`, {
      headers: {
        'X-API-Key': apiKey
      }
    })
      .then((res) => res.json())
      .then((data) => {
        setDevices(data);
        if (data.length > 0) {
          setSelectedDevice(data[0]);
        }
      });
  }, [apiUrl]);

  const fetchSensorData = () => {
    if (selectedDevice) {
      fetch(`${apiUrl}/api/sensor-data?device_id=${selectedDevice}&hours=${hours}`, {
        headers: {
          'X-API-Key': apiKey
        }
      })
        .then((res) => res.json())
        .then(setSensorData);
    }
  };

  useEffect(() => {
    fetchSensorData();
  }, [selectedDevice, hours]);

  const formatTime = (timestamp) => {
    const date = new Date(timestamp);
    return date.toLocaleString('en-US', {
      timeZone: 'America/New_York',
      year: 'numeric',
      month: 'short',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: true,
    });
  };

  // Prepare data for Recharts
  const chartData = sensorData.map((reading) => ({
    ...reading,
    // We'll handle time formatting in the chart's tooltip/ticks
  }));

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Top Navigation Bar */}
      <nav className="bg-blue-600 p-4 mb-6">
        <div className="max-w-7xl mx-auto text-white font-bold text-2xl">
          IoT Sensor Dashboard
        </div>
      </nav>

      {/* Main Container */}
      <div className="max-w-7xl mx-auto px-6">
        {/* Controls */}
        <div className="flex flex-col sm:flex-row items-start sm:items-center gap-4 mb-6">
          {/* Device Selector */}
          <div className="flex flex-col sm:flex-row items-start sm:items-center gap-2">
            <label className="font-semibold">Select Device:</label>
            <select
              value={selectedDevice}
              onChange={(e) => setSelectedDevice(e.target.value)}
              className="border border-gray-300 p-2 rounded w-full sm:w-auto"
            >
              {devices.map((device) => (
                <option key={device} value={device}>
                  {device}
                </option>
              ))}
            </select>
          </div>

          {/* Hours & Refresh */}
          <div className="flex flex-col sm:flex-row items-start sm:items-center gap-2">
            <label className="font-semibold">Last Hours:</label>
            <input
              type="number"
              value={hours}
              onChange={(e) => setHours(e.target.value)}
              min="1"
              className="border border-gray-300 p-2 rounded w-full sm:w-20"
            />
            <button
              onClick={fetchSensorData}
              className="bg-blue-500 text-white p-2 rounded hover:bg-blue-600"
            >
              Refresh Data
            </button>
          </div>
        </div>

        {/* Chart & Table in Responsive Columns */}
        <div className="flex flex-col md:flex-row gap-4">
          {/* Chart Card */}
          <div className="bg-white rounded-lg shadow-md p-4 flex-1">
            <h2 className="text-xl font-bold mb-4">Temperature & Humidity</h2>
            <div className="w-full h-80">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={chartData}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis
                    dataKey="time"
                    tickFormatter={(time) => {
                      const date = new Date(time);
                      return date.toLocaleTimeString('en-US', {
                        timeZone: 'America/New_York',
                        hour: '2-digit',
                        minute: '2-digit',
                      });
                    }}
                  />
                  <YAxis />
                  <Tooltip 
                    labelFormatter={(time) => formatTime(time)} 
                    formatter={(value, name, props) => {
                      if (name === 'Temp (°F)' || name === 'Humidity (%)') {
                        return [value?.toFixed(1) || '----', name];
                      }
                      return [value || '----', name];
                    }}
                    content={({ active, payload, label }) => {
                      if (active && payload && payload.length) {
                        const data = payload[0].payload;
                        return (
                          <div className="bg-white p-3 border border-gray-200 shadow-md rounded">
                            <p className="font-semibold">{formatTime(label)}</p>
                            {data.event_type && (
                              <p className="text-gray-600">Event: {data.event_type}</p>
                            )}
                            {payload.map((entry, index) => (
                              <p key={index} style={{ color: entry.color }}>
                                {entry.name}: {entry.value?.toFixed(1) || '----'}
                              </p>
                            ))}
                          </div>
                        );
                      }
                      return null;
                    }}
                  />
                  <Legend />
                  <Line
                    type="monotone"
                    dataKey="temperature"
                    name="Temp (°F)"
                    stroke="#8884d8"
                    dot={false}
                  />
                  <Line
                    type="monotone"
                    dataKey="humidity"
                    name="Humidity (%)"
                    stroke="#82ca9d"
                    dot={false}
                  />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </div>

          {/* Table Card */}
          <div className="bg-white rounded-lg shadow-md p-4 flex-1">
            <h2 className="text-xl font-bold mb-4">Sensor Readings</h2>
            <div className="overflow-x-auto">
              <table className="table-auto w-full border border-gray-300 rounded">
                <thead className="bg-blue-50">
                  <tr>
                    <th className="px-4 py-2 text-left font-semibold text-blue-800 uppercase">
                      Time (ET)
                    </th>
                    {/* Event Type Header */}
                    <th className="px-4 py-2 text-left font-semibold text-blue-800 uppercase">
                      Event Type
                    </th>
                    <th className="px-4 py-2 text-right font-semibold text-blue-800 uppercase">
                      Temp (°F)
                    </th>
                    <th className="px-4 py-2 text-right font-semibold text-blue-800 uppercase">
                      Humidity (%)
                    </th>
                    <th className="px-4 py-2 text-right font-semibold text-blue-800 uppercase">
                      Pressure (inHg)
                    </th>
                    <th className="px-4 py-2 text-right font-semibold text-blue-800 uppercase">
                      Motion
                    </th>
                    <th className="px-4 py-2 text-right font-semibold text-blue-800 uppercase">
                      Switch
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {sensorData.map((reading, index) => (
                    <tr
                      key={index} // Consider using a more stable key if available (e.g., reading.timestamp + reading.device_id)
                      className={`border-t border-gray-300 ${
                        index % 2 === 0 ? 'bg-white' : 'bg-gray-50'
                      } hover:bg-blue-50 transition-colors duration-200`}
                    >
                      <td className="px-4 py-2">
                        {formatTime(reading.time)}
                      </td>
                      {/* Event Type Data Cell - using null coalescing operator */}
                      <td className="px-4 py-2 text-left">{reading.event_type ?? '----'}</td>
                      <td className="px-4 py-2 text-right">
                        {/* Handle potential null values from DB before toFixed */}
                        {reading.temperature != null ? reading.temperature.toFixed(1) : '----'}
                      </td>
                      <td className="px-4 py-2 text-right">
                        {reading.humidity != null ? reading.humidity.toFixed(1) : '----'}
                      </td>
                      <td className="px-4 py-2 text-right">
                        {reading.pressure != null ? reading.pressure.toFixed(1) : '----'}
                      </td>
                      <td className="px-4 py-2 text-right">{reading.motion ?? '----'}</td>
                      <td className="px-4 py-2 text-right">{reading.switch ?? '----'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

export default App;