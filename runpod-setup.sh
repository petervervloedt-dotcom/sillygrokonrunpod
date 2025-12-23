bash -c 'cat > /workspace/start.sh << '\''SCRIPTEND'\''
#!/bin/bash
# RunPod Template: SillyTavern + Kobold + AllTalk
# Met Network Volume ondersteuning

set -e

echo "================================"
echo "RunPod SillyTavern Setup Start"
echo "================================"

# Check of volume gemount is
if [ -d "/runpod-volume" ]; then
    echo "✅ Network Volume gedetecteerd op /runpod-volume"
    STORAGE_PATH="/runpod-volume"
    WORKSPACE_PATH="/workspace"
    
    # Maak symbolische links van volume naar workspace
    echo "Configureren volume links..."
    
    # Models op volume, link naar workspace
    mkdir -p $STORAGE_PATH/models
    if [ ! -L "$WORKSPACE_PATH/models" ]; then
        ln -sf $STORAGE_PATH/models $WORKSPACE_PATH/models
    fi
    
    # SillyTavern data op volume (chats, settings, characters)
    mkdir -p $STORAGE_PATH/SillyTavern-data
    
else
    echo "⚠️  Geen Network Volume - gebruik lokale opslag"
    STORAGE_PATH="/workspace"
    WORKSPACE_PATH="/workspace"
fi

cd $WORKSPACE_PATH

# Controleer of dit de eerste keer is
if [ ! -f "$STORAGE_PATH/.setup_complete" ]; then
    echo "Eerste keer setup - installeren van alles..."
    
    # 1. Basis installaties
    echo "[1/7] Installeren dependencies..."
    apt update && apt install -y nginx nano nodejs npm git wget curl

    # 2. SillyTavern
    echo "[2/7] Clonen SillyTavern..."
    if [ -d "$STORAGE_PATH/SillyTavern" ]; then
        echo "SillyTavern bestaat al op volume"
        cd $STORAGE_PATH/SillyTavern
        git pull
        npm install
    else
        cd $STORAGE_PATH
        git clone https://github.com/SillyTavern/SillyTavern.git
        cd SillyTavern
        npm install
    fi
    
    # Link naar workspace als we op volume zitten
    if [ "$STORAGE_PATH" != "$WORKSPACE_PATH" ]; then
        ln -sf $STORAGE_PATH/SillyTavern $WORKSPACE_PATH/SillyTavern
    fi

    # 3. Kobold
    echo "[3/7] Clonen en compileren Kobold..."
    if [ -d "$STORAGE_PATH/koboldcpp" ]; then
        echo "Kobold bestaat al op volume"
        cd $STORAGE_PATH/koboldcpp
        git pull
        make LLAMA_CUBLAS=1
    else
        cd $STORAGE_PATH
        git clone https://github.com/LostRuins/koboldcpp.git
        cd koboldcpp
        make LLAMA_CUBLAS=1
    fi
    
    if [ "$STORAGE_PATH" != "$WORKSPACE_PATH" ]; then
        ln -sf $STORAGE_PATH/koboldcpp $WORKSPACE_PATH/koboldcpp
    fi

    # 4. AllTalk TTS
    echo "[4/7] Clonen AllTalk..."
    if [ -d "$STORAGE_PATH/alltalk_tts" ]; then
        echo "AllTalk bestaat al op volume"
        cd $STORAGE_PATH/alltalk_tts
        git pull
        pip install -r requirements.txt
    else
        cd $STORAGE_PATH
        git clone https://github.com/erew123/alltalk_tts.git
        cd alltalk_tts
        pip install -r requirements.txt
    fi
    
    if [ "$STORAGE_PATH" != "$WORKSPACE_PATH" ]; then
        ln -sf $STORAGE_PATH/alltalk_tts $WORKSPACE_PATH/alltalk_tts
    fi

    # 5. Model downloaden
    echo "[5/7] Downloaden AI model (dit duurt even)..."
    mkdir -p $STORAGE_PATH/models
    cd $STORAGE_PATH/models
    if [ ! -f "NemoMix-Unleashed-12B-Q4_K_S.gguf" ]; then
        wget -O NemoMix-Unleashed-12B-Q4_K_S.gguf "https://huggingface.co/bartowski/NemoMix-Unleashed-12B-GGUF/resolve/main/NemoMix-Unleashed-12B-Q4_K_S.gguf?download=true"
    else
        echo "Model al gedownload - overslaan"
    fi

    # Markeer setup als compleet
    touch $STORAGE_PATH/.setup_complete
    echo "Eerste setup compleet!"
else
    echo "✅ Setup al uitgevoerd - hergebruiken bestaande installatie"
    
    # Zorg dat links bestaan
    if [ "$STORAGE_PATH" != "$WORKSPACE_PATH" ]; then
        ln -sf $STORAGE_PATH/SillyTavern $WORKSPACE_PATH/SillyTavern
        ln -sf $STORAGE_PATH/koboldcpp $WORKSPACE_PATH/koboldcpp
        ln -sf $STORAGE_PATH/alltalk_tts $WORKSPACE_PATH/alltalk_tts
        ln -sf $STORAGE_PATH/models $WORKSPACE_PATH/models
    fi
fi

# 6. Nginx configuratie (altijd overschrijven voor updates)
echo "[6/7] Configureren Nginx reverse proxy..."
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-enabled/proxy.conf << '\''NGINXEOF'\''
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 100M;

    location / {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }

    location /api/kobold/ {
        proxy_pass http://localhost:5001/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 300;
    }

    location /alltalk/ {
        proxy_pass http://localhost:7851/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }
}
NGINXEOF

nginx -t && (killall nginx 2>/dev/null || true) && nginx

# 7. Start alle services
echo "[7/7] Starten services..."

# Stop eventuele oude processen
pkill -f koboldcpp || true
pkill -f "node server.js" || true
pkill -f "python server.py" || true

# Start Kobold
cd $WORKSPACE_PATH/koboldcpp
nohup ./koboldcpp.py $WORKSPACE_PATH/models/NemoMix-Unleashed-12B-Q4_K_S.gguf --gpulayers 999 --contextsize 8192 --threads 8 --port 5001 --usecublas > $WORKSPACE_PATH/kobold.log 2>&1 &
KOBOLD_PID=$!

# Start AllTalk
cd $WORKSPACE_PATH/alltalk_tts
nohup python server.py --port 7851 > $WORKSPACE_PATH/alltalk.log 2>&1 &
ALLTALK_PID=$!

# Start SillyTavern
cd $WORKSPACE_PATH/SillyTavern
nohup node server.js --listen > $WORKSPACE_PATH/sillytavern.log 2>&1 &
SILLYTAVERN_PID=$!

# Wacht even tot services opstarten
sleep 5

echo ""
echo "================================"
echo "✅ SETUP COMPLEET!"
echo "================================"
echo "Open in browser: http://[RUNPOD-IP]/"
echo ""
echo "Kobold API: http://localhost/api/kobold"
echo "AllTalk API: http://localhost/alltalk"
echo ""
echo "Logs: tail -f /workspace/*.log"
echo "================================"

# Keep container running
tail -f /workspace/sillytavern.log
SCRIPTEND
chmod +x /workspace/start.sh && /workspace/start.sh'
```

**Waarom deze constructie?**

De `bash -c 'cat > file << '\''SCRIPTEND'\''` constructie:
- Maakt een bestand `/workspace/start.sh`
- Vult het met je volledige script
- Maakt het executable
- Voert het uit

Dit is nodig omdat RunPod's "Container Start Command" veld één enkele command verwacht, niet een volledig multi-line script.

**Visueel:**
```
RunPod Template Interface
┌─────────────────────────────────────┐
│ Container Start Command:            │
│ ┌─────────────────────────────────┐ │
│ │ bash -c 'cat > /workspace/st... │ │ ← Hier plak je
│ │ [HELE SCRIPT]                   │ │    het hele blok
│ │ ...                             │ │
│ │ SCRIPTEND                       │ │
│ │ chmod +x ...'                   │ │
│ └─────────────────────────────────┘ │
│                                     │
│ [Save Template]                     │
└─────────────────────────────────────┘
