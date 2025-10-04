#!/usr/bin/env bash
set -euo pipefail
# Created By Pratik Jhaveri
# ========= CONFIG =========
CODE_MODEL_NAME="codellama-7b-instruct.Q4_K_M.gguf"
CODE_MODEL_URL="https://huggingface.co/TheBloke/CodeLlama-7B-Instruct-GGUF/resolve/main/codellama-7b-instruct.Q4_K_M.gguf?download=true"

EMBED_MODEL_NAME="bge-small-en-v1_5.gguf"
EMBED_MODEL_URL="https://huggingface.co/BAAI/bge-small-en-v1.5-GGUF/resolve/main/bge-small-en-v1_5.gguf?download=true"

AI_USER="${SUDO_USER:-$USER}"   # run services as your login user
CPU_THREADS="4"
CTX_SIZE="4096"

# ========= UTILS =========
log() { printf "\n\033[1;36m[ai-setup]\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31m[ai-setup:ERROR]\033[0m %s\n" "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

detect_wsl() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "1"; else echo "0"; fi
}

# ========= PHASE 0: BASE =========
log "Updating system and installing base packages…"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

log "Installing dependencies (git, build tools, OpenBLAS, Python, Docker)…"
sudo apt-get install -y \
  git build-essential cmake libopenblas-dev \
  python3 python3-pip curl ca-certificates \
  docker.io docker-compose-plugin jq htop

log "Adding $AI_USER to docker group…"
sudo usermod -aG docker "$AI_USER" || true

# Optional but helpful on HDD: create swap if none
if ! swapon --show | grep -q 'partition\|file'; then
  log "No swap detected; creating 16G swapfile (good for HDD + large ctx)…"
  sudo fallocate -l 16G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=16384
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  fi
else
  log "Swap already present—skipping."
fi

# ========= PHASE 1: DIRS =========
log "Creating directories…"
sudo -u "$AI_USER" mkdir -p "/home/$AI_USER/llama.cpp" "/home/$AI_USER/models" "/home/$AI_USER/rag/{models,app,qdrant_storage}"
sudo chown -R "$AI_USER":"$AI_USER" "/home/$AI_USER"

# ========= PHASE 2: BUILD llama.cpp =========
if [ ! -d "/home/$AI_USER/llama.cpp/.git" ]; then
  log "Cloning llama.cpp…"
  sudo -u "$AI_USER" git clone https://github.com/ggerganov/llama.cpp.git "/home/$AI_USER/llama.cpp"
fi

log "Building llama.cpp with OpenBLAS… (this can take a few minutes)"
pushd "/home/$AI_USER/llama.cpp" >/dev/null
sudo -u "$AI_USER" make -j"$(nproc)" LLAMA_BLAS=1 LLAMA_BLAS_VENDOR=OpenBLAS
popd >/dev/null

# ========= PHASE 3: DOWNLOAD MODELS =========
download_model() {
  local url="$1" name="$2" dest="/home/$AI_USER/models/$2"
  if [ -f "$dest" ]; then
    log "Model $name already exists—skipping download."
    return
  fi
  log "Downloading $name …"
  # Some Hugging Face links require cookies/acceptance; fall back instructions if it fails.
  if ! sudo -u "$AI_USER" curl -L --fail -o "$dest" "$url"; then
    log "Automatic download failed. This can happen if the model requires license acceptance."
    log "Manual fix: open this URL in a browser, accept terms, then place the file at: $dest"
    log "URL: $url"
    fail "Model download failed for $name"
  fi
}

download_model "$CODE_MODEL_URL" "$CODE_MODEL_NAME"
download_model "$EMBED_MODEL_URL" "$EMBED_MODEL_NAME"

# ========= PHASE 4: SYSTEMD for code model =========
log "Creating systemd service for the bare-metal code model…"
CODE_SERVICE_PATH="/etc/systemd/system/llama-code.service"
sudo tee "$CODE_SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Llama Code Model (llama.cpp)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$AI_USER
WorkingDirectory=/home/$AI_USER/llama.cpp
Environment=OPENBLAS_NUM_THREADS=1
ExecStart=/home/$AI_USER/llama.cpp/server -m /home/$AI_USER/models/$CODE_MODEL_NAME -t $CPU_THREADS --ctx-size $CTX_SIZE --host 0.0.0.0 --port 8080
Restart=always
RestartSec=5

# CPU pinning hint (uncomment if desired):
# ExecStartPre=/usr/bin/taskset -pc 0-3 \$MAINPID

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable llama-code
sudo systemctl start llama-code
sleep 2
sudo systemctl --no-pager --full status llama-code || true

# ========= PHASE 5: DOCKER SERVICES =========
log "Starting Docker and enabling at boot…"
sudo systemctl enable docker
sudo systemctl start docker
sleep 2

log "Launching Qdrant (persistent vector DB)…"
docker rm -f qdrant >/dev/null 2>&1 || true
docker run -d --name qdrant \
  -p 6333:6333 \
  -v "/home/$AI_USER/rag/qdrant_storage:/qdrant/storage" \
  qdrant/qdrant:latest

log "Launching embedding server (llama.cpp in Docker)…"
docker rm -f embed-llm >/dev/null 2>&1 || true
docker run -d --name embed-llm \
  -p 8081:8081 \
  -v "/home/$AI_USER/rag/models:/models:ro" \
  ghcr.io/ggerganov/llama.cpp:full \
  ./server -m "/models/$EMBED_MODEL_NAME" --embedding -t $CPU_THREADS --host 0.0.0.0 --port 8081

log "Writing RAG API (FastAPI) app…"
RAG_APP="/home/$AI_USER/rag/app/ragd.py"
sudo -u "$AI_USER" tee "$RAG_APP" >/dev/null <<'PY'
from fastapi import FastAPI, Body
import httpx, os

app = FastAPI()
CODE = "http://host.docker.internal:8080/v1"
EMB  = "http://embed-llm:8081/v1"
QDR  = "http://qdrant:6333"
COLL = "webdocs"

async def embed_text(text: str):
    async with httpx.AsyncClient(timeout=60) as c:
        r = await c.post(f"{EMB}/embeddings", json={"input": text})
        r.raise_for_status()
        return r.json()["data"][0]["embedding"]

@app.on_event("startup")
async def init_qdrant():
    async with httpx.AsyncClient() as c:
        await c.put(f"{QDR}/collections/{COLL}", json={"vectors":{"size":384,"distance":"Cosine"}})

@app.post("/index")
async def index(doc: dict = Body(...)):
    # doc = { "url": str, "title": str, "chunks": [str, ...] }
    points = []
    async with httpx.AsyncClient(timeout=300) as c:
        for i, chunk in enumerate(doc.get("chunks", [])):
            vec = await embed_text(chunk)
            points.append({
                "id": (hash((doc.get("url",""), i)) & ((1<<63)-1)),
                "vector": vec,
                "payload": {"url": doc.get("url",""), "title": doc.get("title",""), "chunk": chunk}
            })
        if points:
            await c.put(f"{QDR}/collections/{COLL}/points?wait=true", json={"points": points})
    return {"upserted": len(points)}

@app.post("/answer")
async def answer(body: dict = Body(...)):
    query = body["query"]
    top_k = int(body.get("top_k", 6))
    async with httpx.AsyncClient(timeout=180) as c:
        qvec = await embed_text(query)
        sr = await c.post(f"{QDR}/collections/{COLL}/points/search",
                          json={"vector": qvec, "limit": top_k})
        hits = sr.json().get("result", [])
        context = "\n\n".join(h.get("payload", {}).get("chunk", "") for h in hits)
        prompt = [
            {"role": "system", "content": "You are a precise coding assistant. Cite sources when applicable."},
            {"role": "user", "content": f"Question:\n{query}\n\nContext (snippets):\n{context}"}
        ]
        cr = await c.post(f"{CODE}/chat/completions", json={
            "model": "local-code",
            "messages": prompt,
            "temperature": 0.2
        })
        cr.raise_for_status()
        return {
            "answer": cr.json(),
            "sources": [h.get("payload", {}).get("url") for h in hits]
        }
PY

log "Launching RAG API container…"
docker rm -f ragd >/dev/null 2>&1 || true
docker run -d --name ragd \
  -p 8000:8000 \
  -v "/home/$AI_USER/rag/app:/app:ro" \
  --link qdrant:qdrant --link embed-llm:embed-llm \
  --add-host=host.docker.internal:host-gateway \
  python:3.11-alpine sh -c "pip install fastapi uvicorn httpx && uvicorn ragd:app --host 0.0.0.0 --port 8000"

# ========= PHASE 6: BOOT AUTOSTART =========
log "Enabling Docker services autostart via cron @reboot…"
CRONLINE='@reboot /usr/bin/docker start qdrant embed-llm ragd'
( crontab -u "$AI_USER" -l 2>/dev/null | grep -v 'docker start qdrant embed-llm ragd' || true ; echo "$CRONLINE" ) | crontab -u "$AI_USER" -

# ========= PHASE 7: VALIDATION =========
log "Validating endpoints…"
sleep 3
set +e
curl -s http://localhost:8080/v1/models | jq . >/dev/null || log "WARN: Code model check failed (service may still be warming up)"
curl -s -X POST http://localhost:8081/v1/embeddings -H 'Content-Type: application/json' -d '{"input":"hello"}' | jq . >/dev/null || log "WARN: Embeddings check failed"
curl -s http://localhost:6333/collections | jq . >/dev/null || log "WARN: Qdrant check failed"
set -e

log "All done 🎉
- Code model:      http://localhost:8080/v1/chat/completions
- Embeddings:      http://localhost:8081/v1/embeddings
- Qdrant:          http://localhost:6333
- RAG API:         http://localhost:8000

Next steps:
1) Index docs with POST /index on :8000 (send url/title/chunks).
2) Ask questions via POST /answer on :8000.
3) Point VS Code/PHPStorm to http://localhost:8080/v1 for Codex-style completions.

If a Hugging Face model didn’t download (license gate), open the URL in a browser, accept, and place the file at:
  /home/$AI_USER/models/$CODE_MODEL_NAME
  /home/$AI_USER/rag/models/$EMBED_MODEL_NAME
"
