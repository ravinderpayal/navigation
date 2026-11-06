#!/usr/bin/env python3
"""A local stand-in for Google Places and Routes and the charger status feed,
for testing without an API key.

Serves a Delhi -> Jaipur route shaped like NH-48, using the same JSON Google does.
Usage: python3 tool/fake_google.py [port], then build the app with
--dart-define=API_BASE_OVERRIDE=http://10.0.2.2:8787 (10.0.2.2 is the host, seen
from the Android emulator).
"""
import json, sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# A station the feed reports as down, to prove the app avoids it.
DEAD_ID, DEAD_NAME = "dead-station", "TEJU SERVICE STATION"
DEAD = next(c for c in json.load(open(ROOT / "assets" / "free_chargers.json", encoding="utf-8")) if c["name"] == DEAD_NAME)

POINTS = [(28.6139, 77.2090), (28.4595, 77.0266), (28.2000, 76.8200), (27.9000, 76.4000),
          (27.5500, 76.1000), (26.9124, 75.7873)]


def encode(points):
    out, last_lat, last_lng = [], 0, 0

    def chunk(value):
        value = ~(value << 1) if value < 0 else value << 1
        while value >= 0x20:
            out.append(chr((0x20 | (value & 0x1f)) + 63))
            value >>= 5
        out.append(chr(value + 63))

    for lat, lng in points:
        a, b = round(lat * 1e5), round(lng * 1e5)
        chunk(a - last_lat)
        chunk(b - last_lng)
        last_lat, last_lng = a, b
    return "".join(out)


ROUTE = {
    "duration": "16200s",
    "routeToken": "fake-token",
    "polyline": {"encodedPolyline": encode(POINTS)},
    "legs": [{"steps": [
        {"distanceMeters": 25000, "staticDuration": "2700s"},  # Delhi streets
        {"distanceMeters": 200000, "staticDuration": "9000s"},  # highway
        {"distanceMeters": 15000, "staticDuration": "1500s"},  # Jaipur streets
    ]}],
    "travelAdvisory": {"speedReadingIntervals": [
        {"startPolylinePointIndex": 0, "endPolylinePointIndex": 5, "speed": "NORMAL"},
    ]},
}


class Handler(BaseHTTPRequestHandler):
    def _send(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        print("GET", self.path, flush=True)
        if self.path.endswith("/stations/discovery"):
            self._send({"updatedAt": datetime.now(timezone.utc).isoformat(), "stations": [
                {"id": DEAD_ID, "name": DEAD_NAME, "latitude": DEAD["lat"], "longitude": DEAD["lng"],
                 "connectors": [], "available": False}]})
            return
        if "/api/stations/" in self.path:
            self._send({"station": {"id": DEAD_ID, "connectors": [
                {"id": "a", "available": False, "connectorType": "IEC_62196_T2_COMBO",
                 "currentType": "DC", "statusLabel": "Out of service"}]}})
            return
        self._send({"displayName": {"text": "Jaipur"},
                    "location": {"latitude": 26.9124, "longitude": 75.7873}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        print("POST", self.path, json.dumps(body)[:160], "mask:", self.headers.get("X-Goog-FieldMask"), flush=True)
        if "autocomplete" in self.path:
            text = body.get("input", "")
            self._send({"suggestions": [{"placePrediction": {
                "placeId": "jaipur", "text": {"text": f"Jaipur, Rajasthan ({text})"},
                "structuredFormat": {"mainText": {"text": f"Jaipur ({text})"},
                                     "secondaryText": {"text": "Rajasthan, India"}},
            }}]})
        elif "searchText" in self.path or "searchNearby" in self.path:
            self._send({"places": []})
        elif "computeRoutes" in self.path:
            if "routes.distanceMeters" == self.headers.get("X-Goog-FieldMask"):
                self._send({"routes": [{"distanceMeters": 3500}]})
            else:
                self._send({"routes": [ROUTE]})
        else:
            self._send({"error": {"message": "unknown path"}}, 404)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
