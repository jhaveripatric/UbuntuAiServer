
AI INSTALL

COMPLETE STEP-BY-STEP SETUP
PHASE 1 – Install Ubuntu Server 24.04 (minimal)
1. Download ISO: https://ubuntu.com/download/server
2. Create bootable USB (Rufus or BalenaEtcher).
3. Boot from USB → choose Install Ubuntu Server (Minimal).
4. Options during install:
    * No GUI, no snaps except SSH.
    * Enable OpenSSH Server.
    * Partition whole disk automatically.
    * Username: aiuser (or as you like).
    * Auto-login enabled.
5. Reboot → login.

PHASE 2 – Base system setup

sudo apt update && sudo apt -y upgrade
sudo apt install -y git build-essential cmake libopenblas-dev python3 python3-pip docker.io docker-compose-plugin htop curl
sudo usermod -aG docker $USER
newgrp docker

PHASE 3 – Optimize HDD for AI workloads

# Enable write caching
sudo hdparm -W1 /dev/sda
# Optional: mount model directory with noatime
sudo nano /etc/fstab
# Add (example):
# UUID=xxxxxx /mnt/data ext4 defaults,noatime 0 2
(You can check the UUID using sudo blkid.)

PHASE 4 – Build the Code Model runtime (bare-metal)

cd ~
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
make -j4 LLAMA_BLAS=1 LLAMA_BLAS_VENDOR=OpenBLAS
Download the model

mkdir -p ~/models
cd ~/models
wget https://huggingface.co/TheBloke/CodeLlama-7B-Instruct-GGUF/resolve/main/codellama-7b-instruct.Q4_K_M.gguf
Run

cd ~/llama.cpp
export OPENBLAS_NUM_THREADS=1
taskset -c 0-3 ./server \
-m ~/models/codellama-7b-instruct.Q4_K_M.gguf \
-t 4 --ctx-size 4096 --host 0.0.0.0 --port 8080
✅ Test:

curl http://localhost:8080/v1/models

PHASE 5 – Install Docker services (persistent RAG)
1️⃣ Directory layout

mkdir -p ~/rag/{models,app,qdrant_storage}
2️⃣ Embeddings server

cd ~/rag/models
wget https://huggingface.co/BAAI/bge-small-en-v1.5-GGUF/resolve/main/bge-small-en-v1_5.gguf

docker run -d --name embed-llm \
-p 8081:8081 \
-v ~/rag/models:/models:ro \
ghcr.io/ggerganov/llama.cpp:full \
./server -m /models/bge-small-en-v1_5.gguf --embedding -t 4 --host 0.0.0.0 --port 8081
3️⃣ Qdrant (permanent memory)

docker run -d --name qdrant \
-p 6333:6333 \
-v ~/rag/qdrant_storage:/qdrant/storage \
qdrant/qdrant:latest
4️⃣ RAG API

nano ~/rag/app/ragd.py
(Paste same permanent version from earlier — it already handles storage, indexing, answering.)
Then run:

docker run -d --name ragd \
-p 8000:8000 \
-v ~/rag/app:/app:ro \
--link qdrant:qdrant --link embed-llm:embed-llm \
--add-host=host.docker.internal:host-gateway \
python:3.11-alpine sh -c "pip install fastapi uvicorn httpx && uvicorn ragd:app --host 0.0.0.0 --port 8000"

PHASE 6 – Autostart on boot
Create systemd services
1. Code model

sudo tee /etc/systemd/system/llama-code.service > /dev/null <<'EOF'
[Unit]
Description=Llama Code Model
After=network.target

[Service]
ExecStart=/home/aiuser/llama.cpp/server -m /home/aiuser/models/codellama-7b-instruct.Q4_K_M.gguf -t 4 --ctx-size 4096 --host 0.0.0.0 --port 8080
Restart=always
User=aiuser
Environment=OPENBLAS_NUM_THREADS=1

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable llama-code
2. Docker stack
   Add to cron:

crontab -e
@reboot docker start qdrant embed-llm ragd

PHASE 7 – Verify all components
After reboot:

sudo systemctl status llama-code
docker ps
curl http://localhost:8080/v1/models
curl http://localhost:8081/v1/embeddings
curl http://localhost:6333/collections
Everything should respond ✅

PHASE 8 – First RAG test

curl -s -X POST http://localhost:8000/index \
-H 'Content-Type: application/json' \
-d '{"url":"https://example.com","title":"Example","chunks":["PHP array merge","Laravel service container explanation"]}'

curl -s -X POST http://localhost:8000/answer \
-H 'Content-Type: application/json' \
-d '{"query":"Write a PHP function to merge two sorted arrays"}'
You should get a code answer + sources.

PHASE 9 – Hardening & optimization
* Swap file (HDD safe fallback):    sudo fallocate -l 16G /swapfile
* sudo chmod 600 /swapfile
* sudo mkswap /swapfile
* sudo swapon /swapfile
* echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
*   
* Avoid journald log bloat:    sudo journalctl --vacuum-time=3d
*   
* Monitor performance: htop → check CPU saturation (threads = 4 max).
* Keep Qdrant indexes healthy: occasionally curl -X POST localhost:6333/collections/webdocs/points/scroll to verify integrity.

PHASE 10 – Optional add-ons
* Add crawler (trafilatura) to RAG for automatic web learning.
* Add SearXNG container for local web search integration.
* VS Code / PHPStorm integration: point OpenAI plugin base URL to http://localhost:8080/v1.

PHASE 11 – Common pitfalls
Problem	Fix
Slow responses	HDD I/O: lower --ctx-size or add 16 GB swap
“Qdrant refused connection”	docker start qdrant
“Port already in use”	change port in systemd file
“Killed” / OOM	reduce context, ensure swap active
Docker not autostarting	add to crontab as shown
llama.cpp missing libopenblas	re-make with LLAMA_BLAS=1
✅ Final outcome
You’ll have a stable, offline-capable AI coding environment that:
* Lives entirely on your laptop (no USB/SSD needed)
* Learns & remembers via persistent Qdrant RAG
* Uses minimal resources (~2 GB idle, 15–18 GB active)
* Boots and runs automatically
* Lets you query via HTTP or IDE just like Codex


How to use

Install Ubuntu Server 24.04 (Minimal) with OpenSSH enabled.

Log in and run:

nano ~/ai_setup.sh
# paste the ENTIRE script below, save, exit

chmod +x ~/ai_setup.sh
sudo ./ai_setup.sh


When the script finishes:

# quick checks
curl http://localhost:8080/v1/models          # code model
curl -s -X POST http://localhost:8081/v1/embeddings -H 'Content-Type: application/json' -d '{"input":"hello"}'
curl http://localhost:6333/collections        # qdrant


Test RAG:

# seed one fake "doc"
curl -s -X POST http://localhost:8000/index \
-H 'Content-Type: application/json' \
-d '{"url":"https://example.com","title":"Example","chunks":["PHP array merge","Laravel service container"]}'

# ask a question
curl -s -X POST http://localhost:8000/answer \
-H 'Content-Type: application/json' \
-d '{"query":"Write a PHP function to merge two sorted arrays"}' | jq .