#!/bin/bash
# Test Gemini Batch Processing — exercises each API step independently
# Usage: ./test_gemini_batch.sh <GEMINI_API_KEY> [model_id]

set -euo pipefail

API_KEY="${1:?Usage: $0 <GEMINI_API_KEY> [model_id]}"
MODEL="${2:-gemini-2.5-flash-lite}"
BASE="https://generativelanguage.googleapis.com/v1beta"
UPLOAD_BASE="https://generativelanguage.googleapis.com/upload/v1beta"
DOWNLOAD_BASE="https://generativelanguage.googleapis.com/download/v1beta"
TMPD="$(mktemp -d)"
trap "rm -rf $TMPD" EXIT

echo "=== Gemini Batch Processing Test ==="
echo "Model: $MODEL"
echo ""

# --- Step 0: Verify API key with a simple call ---
echo "--- Step 0: Verify API key ---"

# Create a tiny test JPEG via python
python3 -c "
from PIL import Image
import io
img = Image.new('RGB', (2, 2), color='white')
buf = io.BytesIO()
img.save(buf, format='JPEG')
open('$TMPD/tiny.jpg', 'wb').write(buf.getvalue())
" 2>/dev/null || python3 -c "
import struct
# Minimal 1x1 JPEG
jpg = bytes.fromhex('ffd8ffe000104a46494600010100000100010000ffdb004300080606070605080707070909080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c1c28372929302f3134341f273d3d38323c2e333432ffc0000b080001000101011100ffc4001f0000010501010101010100000000000000000102030405060708090a0bffc400b5100002010303020403050504040000017d01020300041105122131410613516107227114328191a1082342b1c11552d1f0243362728209160a1718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9faffda00080101003f007b94110000ffd9')
open('$TMPD/tiny.jpg', 'wb').write(jpg)
"

TINY_B64=$(base64 -i "$TMPD/tiny.jpg" | tr -d '\n')

# Build request JSON via python to avoid shell quoting issues
python3 -c "
import json
body = {
    'contents': [{'parts': [
        {'inlineData': {'mimeType': 'image/jpeg', 'data': '$TINY_B64'}},
        {'text': 'Say hello.'}
    ]}]
}
open('$TMPD/single_req.json', 'w').write(json.dumps(body))
"

RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    "${BASE}/models/${MODEL}:generateContent?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "@$TMPD/single_req.json")

HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
JSON_BODY=$(echo "$RESP" | sed '/HTTP_CODE:/d')

echo "HTTP: $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAILED: API key or model not working"
    echo "$JSON_BODY" | python3 -m json.tool 2>/dev/null || echo "$JSON_BODY"
    exit 1
fi
echo "OK: API key verified"
echo ""

# --- Step 1: Build JSONL batch request ---
echo "--- Step 1: Build JSONL batch request ---"

python3 -c "
import json
line = {
    'key': 'file-0',
    'request': {
        'contents': [{'parts': [
            {'inlineData': {'mimeType': 'image/jpeg', 'data': '$TINY_B64'}},
            {'text': 'Describe this image in one sentence.'}
        ]}]
    }
}
open('$TMPD/batch.jsonl', 'w').write(json.dumps(line) + '\n')
"

JSONL_SIZE=$(wc -c < "$TMPD/batch.jsonl" | tr -d ' ')
echo "JSONL file: $JSONL_SIZE bytes"
echo ""

# --- Step 2: Upload JSONL via File API ---
echo "--- Step 2a: Initialize resumable upload ---"

INIT_RESP=$(curl -s -i \
    "${UPLOAD_BASE}/files?key=${API_KEY}" \
    -X POST \
    -H "X-Goog-Upload-Protocol: resumable" \
    -H "X-Goog-Upload-Command: start" \
    -H "X-Goog-Upload-Header-Content-Length: $JSONL_SIZE" \
    -H "X-Goog-Upload-Header-Content-Type: application/jsonl" \
    -H "Content-Type: application/json" \
    -d '{"file": {"display_name": "batch_ocr_test"}}')

UPLOAD_URL=$(echo "$INIT_RESP" | grep -i "x-goog-upload-url:" | sed 's/[^:]*: //' | tr -d '\r\n')
INIT_HTTP=$(echo "$INIT_RESP" | head -1 | awk '{print $2}')

echo "HTTP: $INIT_HTTP"

if [ -z "$UPLOAD_URL" ]; then
    echo "FAILED: No upload URL returned"
    echo "Response:"
    echo "$INIT_RESP"
    exit 1
fi
echo "Upload URL obtained"
echo ""

echo "--- Step 2b: Upload file data ---"
UPLOAD_RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    "$UPLOAD_URL" \
    -X POST \
    -H "X-Goog-Upload-Offset: 0" \
    -H "X-Goog-Upload-Command: upload, finalize" \
    --data-binary "@$TMPD/batch.jsonl")

UPLOAD_HTTP=$(echo "$UPLOAD_RESP" | grep "HTTP_CODE:" | cut -d: -f2)
UPLOAD_JSON=$(echo "$UPLOAD_RESP" | sed '/HTTP_CODE:/d')

echo "HTTP: $UPLOAD_HTTP"

FILE_NAME=$(echo "$UPLOAD_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
f = data.get('file', data)
print(f.get('name', ''))
" 2>/dev/null)

if [ -z "$FILE_NAME" ]; then
    echo "FAILED: No file name in upload response"
    echo "$UPLOAD_JSON" | python3 -m json.tool 2>/dev/null || echo "$UPLOAD_JSON"
    exit 1
fi
echo "Uploaded: $FILE_NAME"
echo ""

# --- Step 3: Create batch job — try multiple formats ---
echo "--- Step 3: Create batch job ---"

# Format A: App's current format (models/{model}:batchGenerateContent with batch wrapper)
echo "Trying format A: models/{model}:batchGenerateContent with batch wrapper..."
python3 -c "
import json
body = {'batch': {'display_name': 'test-batch', 'input_config': {'file_name': '$FILE_NAME'}}}
open('$TMPD/batch_a.json', 'w').write(json.dumps(body))
"
RESP_A=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    "${BASE}/models/${MODEL}:batchGenerateContent?key=${API_KEY}" \
    -X POST -H "Content-Type: application/json" -d "@$TMPD/batch_a.json")
HTTP_A=$(echo "$RESP_A" | grep "HTTP_CODE:" | cut -d: -f2)
JSON_A=$(echo "$RESP_A" | sed '/HTTP_CODE:/d')
echo "  HTTP: $HTTP_A"
echo "$JSON_A" | python3 -m json.tool 2>/dev/null || echo "$JSON_A"
echo ""

BATCH_NAME=""
if [ "$HTTP_A" = "200" ]; then
    BATCH_NAME=$(echo "$JSON_A" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
fi

# Format B: Flat body (no batch wrapper)
if [ -z "$BATCH_NAME" ]; then
    echo "Trying format B: flat body..."
    python3 -c "
import json
body = {'display_name': 'test-batch', 'input_config': {'file_name': '$FILE_NAME'}}
open('$TMPD/batch_b.json', 'w').write(json.dumps(body))
"
    RESP_B=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        "${BASE}/models/${MODEL}:batchGenerateContent?key=${API_KEY}" \
        -X POST -H "Content-Type: application/json" -d "@$TMPD/batch_b.json")
    HTTP_B=$(echo "$RESP_B" | grep "HTTP_CODE:" | cut -d: -f2)
    JSON_B=$(echo "$RESP_B" | sed '/HTTP_CODE:/d')
    echo "  HTTP: $HTTP_B"
    echo "$JSON_B" | python3 -m json.tool 2>/dev/null || echo "$JSON_B"
    echo ""
    if [ "$HTTP_B" = "200" ]; then
        BATCH_NAME=$(echo "$JSON_B" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
    fi
fi

# Format C: src instead of input_config
if [ -z "$BATCH_NAME" ]; then
    echo "Trying format C: 'src' field..."
    python3 -c "
import json
body = {'display_name': 'test-batch', 'src': {'file_name': '$FILE_NAME'}}
open('$TMPD/batch_c.json', 'w').write(json.dumps(body))
"
    RESP_C=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        "${BASE}/models/${MODEL}:batchGenerateContent?key=${API_KEY}" \
        -X POST -H "Content-Type: application/json" -d "@$TMPD/batch_c.json")
    HTTP_C=$(echo "$RESP_C" | grep "HTTP_CODE:" | cut -d: -f2)
    JSON_C=$(echo "$RESP_C" | sed '/HTTP_CODE:/d')
    echo "  HTTP: $HTTP_C"
    echo "$JSON_C" | python3 -m json.tool 2>/dev/null || echo "$JSON_C"
    echo ""
    if [ "$HTTP_C" = "200" ]; then
        BATCH_NAME=$(echo "$JSON_C" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
    fi
fi

# Format D: POST to /batches endpoint with model field
if [ -z "$BATCH_NAME" ]; then
    echo "Trying format D: POST /batches with model field..."
    python3 -c "
import json
body = {'display_name': 'test-batch', 'model': 'models/$MODEL', 'src': {'file_name': '$FILE_NAME'}}
open('$TMPD/batch_d.json', 'w').write(json.dumps(body))
"
    RESP_D=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        "${BASE}/batches?key=${API_KEY}" \
        -X POST -H "Content-Type: application/json" -d "@$TMPD/batch_d.json")
    HTTP_D=$(echo "$RESP_D" | grep "HTTP_CODE:" | cut -d: -f2)
    JSON_D=$(echo "$RESP_D" | sed '/HTTP_CODE:/d')
    echo "  HTTP: $HTTP_D"
    echo "$JSON_D" | python3 -m json.tool 2>/dev/null || echo "$JSON_D"
    echo ""
    if [ "$HTTP_D" = "200" ]; then
        BATCH_NAME=$(echo "$JSON_D" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
    fi
fi

# Format E: POST to /batches with input_config
if [ -z "$BATCH_NAME" ]; then
    echo "Trying format E: POST /batches with input_config..."
    python3 -c "
import json
body = {'display_name': 'test-batch', 'model': 'models/$MODEL', 'input_config': {'requests': {'file_name': '$FILE_NAME'}}}
open('$TMPD/batch_e.json', 'w').write(json.dumps(body))
"
    RESP_E=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        "${BASE}/batches?key=${API_KEY}" \
        -X POST -H "Content-Type: application/json" -d "@$TMPD/batch_e.json")
    HTTP_E=$(echo "$RESP_E" | grep "HTTP_CODE:" | cut -d: -f2)
    JSON_E=$(echo "$RESP_E" | sed '/HTTP_CODE:/d')
    echo "  HTTP: $HTTP_E"
    echo "$JSON_E" | python3 -m json.tool 2>/dev/null || echo "$JSON_E"
    echo ""
    if [ "$HTTP_E" = "200" ]; then
        BATCH_NAME=$(echo "$JSON_E" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
    fi
fi

# Format F: Inline requests array (no file upload needed)
if [ -z "$BATCH_NAME" ]; then
    echo "Trying format F: inline requests array..."
    python3 -c "
import json
body = {'requests': [{'contents': [{'parts': [
    {'inlineData': {'mimeType': 'image/jpeg', 'data': '$TINY_B64'}},
    {'text': 'Describe this image.'}
]}]}]}
open('$TMPD/batch_f.json', 'w').write(json.dumps(body))
"
    RESP_F=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        "${BASE}/models/${MODEL}:batchGenerateContent?key=${API_KEY}" \
        -X POST -H "Content-Type: application/json" -d "@$TMPD/batch_f.json")
    HTTP_F=$(echo "$RESP_F" | grep "HTTP_CODE:" | cut -d: -f2)
    JSON_F=$(echo "$RESP_F" | sed '/HTTP_CODE:/d')
    echo "  HTTP: $HTTP_F"
    echo "$JSON_F" | python3 -m json.tool 2>/dev/null || echo "$JSON_F"
    echo ""
    if [ "$HTTP_F" = "200" ]; then
        BATCH_NAME=$(echo "$JSON_F" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
    fi
fi

# Format G: Check model info
if [ -z "$BATCH_NAME" ]; then
    echo "Checking model info for supported methods..."
    MODEL_RESP=$(curl -s "${BASE}/models/${MODEL}?key=${API_KEY}")
    echo "$MODEL_RESP" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('Model:', data.get('name', 'unknown'))
print('Display:', data.get('displayName', 'unknown'))
print('Supported methods:', data.get('supportedGenerationMethods', []))
" 2>/dev/null || echo "$MODEL_RESP" | python3 -m json.tool 2>/dev/null
    echo ""
fi

if [ -z "$BATCH_NAME" ]; then
    echo "=== RESULT: No batch format worked ==="
    echo "The Gemini batch API may not support this model or request format."
    exit 1
fi

echo "=== Batch created: $BATCH_NAME ==="
echo ""

# --- Step 4: Poll status ---
echo "--- Step 4: Poll batch status ---"
for i in $(seq 1 60); do
    STATUS_JSON=$(curl -s "${BASE}/${BATCH_NAME}?key=${API_KEY}")
    STATE=$(echo "$STATUS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('state', d.get('metadata',{}).get('state','UNKNOWN')))
" 2>/dev/null)

    echo "Poll $i: $STATE"

    case "$STATE" in
        *SUCCEEDED*)
            echo "Batch succeeded!"
            echo "$STATUS_JSON" | python3 -m json.tool 2>/dev/null
            break ;;
        *FAILED*|*CANCELLED*|*EXPIRED*)
            echo "Batch ended: $STATE"
            echo "$STATUS_JSON" | python3 -m json.tool 2>/dev/null
            break ;;
        *)
            [ $i -eq 60 ] && echo "Timed out" && echo "$STATUS_JSON" | python3 -m json.tool 2>/dev/null
            sleep 10 ;;
    esac
done

# --- Step 5: Retrieve results ---
RESULT_FILE=$(echo "$STATUS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
dest = d.get('dest', d.get('outputConfig', {}))
print(dest.get('file_name', dest.get('fileName', '')))
" 2>/dev/null)

if [ -n "$RESULT_FILE" ]; then
    echo ""
    echo "--- Step 5: Retrieve results from $RESULT_FILE ---"
    RESULT=$(curl -s "${DOWNLOAD_BASE}/${RESULT_FILE}:download?alt=media&key=${API_KEY}")
    echo "$RESULT" | head -20
fi

echo ""
echo "=== Test complete ==="
