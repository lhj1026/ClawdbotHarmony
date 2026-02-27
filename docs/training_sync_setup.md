# Training Data Sync Server

Lightweight HTTP server that receives training data uploaded from the HarmonyOS client.
Runs alongside the OpenClaw Gateway on the same machine.

## Prerequisites

- Node.js (v16+)

## Start

```bash
node server/training-server.js
```

The server starts on port **18790** (Gateway is 18789).

Data is stored in `server/training-data/` as JSONL files, one per device per day.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check — returns `{ "status": "ok" }` |
| `POST` | `/training/upload` | Upload training records (max 1 MB) |
| `GET` | `/training/stats` | View upload statistics per device |

### POST /training/upload

Request body:

```json
{
  "deviceId": "device_abc",
  "records": [
    { "type": "context_snapshot", "timestamp": 1700000000000, "data": { ... } }
  ]
}
```

Response:

```json
{
  "success": true,
  "receivedCount": 1,
  "serverTime": 1700000000000,
  "file": "device_abc_2025-01-01.jsonl"
}
```

## Client Configuration

In the app settings, set the training sync endpoint to:

```
http://<gateway-ip>:18790
```

where `<gateway-ip>` is the IP address of the machine running the Gateway (same as the Gateway address, different port).

## Verify

```bash
# Health check
curl http://localhost:18790/health

# View stats
curl http://localhost:18790/training/stats
```
